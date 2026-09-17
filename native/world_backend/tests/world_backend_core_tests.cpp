#include "test_harness.hpp"

#include "authority.hpp"
#include "coordinates.hpp"
#include "legacy_seed_hash.hpp"
#include "sha256.hpp"
#include "world_identity.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using namespace voxel::world_backend;

VWB_TEST(coordinates_use_mathematical_floor_and_euclidean_modulo) {
    VWB_EXPECT_EQ(0, *floor_divide(0, 16));
    VWB_EXPECT_EQ(0, *floor_divide(15, 16));
    VWB_EXPECT_EQ(1, *floor_divide(16, 16));
    VWB_EXPECT_EQ(-1, *floor_divide(-1, 16));
    VWB_EXPECT_EQ(-1, *floor_divide(-16, 16));
    VWB_EXPECT_EQ(-2, *floor_divide(-17, 16));
    VWB_EXPECT_EQ(15, *euclidean_modulo(-1, 16));
    VWB_EXPECT_EQ(0, *euclidean_modulo(-16, 16));
    VWB_EXPECT_EQ(15, *euclidean_modulo(-17, 16));
    VWB_EXPECT(!floor_divide(1, 0));
    VWB_EXPECT(!floor_divide(1, -1));
    VWB_EXPECT(!euclidean_modulo(1, 0));
    VWB_EXPECT(!euclidean_modulo(1, -1));
}

VWB_TEST(coordinates_split_and_checked_arithmetic_reject_overflow) {
    const auto address = split_cell({-17, 16, -1}, 16);
    VWB_EXPECT(address.has_value());
    VWB_EXPECT_EQ((SectionAddress{{-2, 1, -1}, {15, 0, 15}}), *address);
    VWB_EXPECT(!split_cell({1, 2, 3}, 0));
    VWB_EXPECT_EQ(std::numeric_limits<std::int32_t>::max(), *checked_add(std::numeric_limits<std::int32_t>::max(), 0));
    VWB_EXPECT(!checked_add(std::numeric_limits<std::int32_t>::max(), 1));
    VWB_EXPECT(!checked_add(std::numeric_limits<std::int32_t>::min(), -1));
    VWB_EXPECT_EQ(32, *checked_multiply(2, 16));
    VWB_EXPECT(!checked_multiply(std::numeric_limits<std::int32_t>::max(), 2));
    VWB_EXPECT(!checked_multiply(std::numeric_limits<std::int32_t>::min(), 2));
    VWB_EXPECT_EQ((CellCoord{-32, 16, 0}), *section_origin({-2, 1, 0}, 16));
    VWB_EXPECT(!section_origin({1, 1, 1}, 0));
    VWB_EXPECT(!section_origin({std::numeric_limits<std::int32_t>::max(), 0, 0}, 16));
    VWB_EXPECT(!section_origin({0, std::numeric_limits<std::int32_t>::max(), 0}, 16));
    VWB_EXPECT(!section_origin({0, 0, std::numeric_limits<std::int32_t>::max()}, 16));
    VWB_EXPECT(CellCoord{} == CellCoord{});
    VWB_EXPECT(!(CellCoord{} == CellCoord{1, 0, 0}));
    VWB_EXPECT(!(CellCoord{} == CellCoord{0, 1, 0}));
    VWB_EXPECT(!(CellCoord{} == CellCoord{0, 0, 1}));
    VWB_EXPECT(!(SectionAddress{} == SectionAddress{{1, 0, 0}, {0, 0, 0}}));
    VWB_EXPECT(!(SectionAddress{} == SectionAddress{{0, 0, 0}, {1, 0, 0}}));
}

VWB_TEST(legacy_hash_matches_frozen_code_point_semantics) {
    VWB_EXPECT(is_unicode_scalar(0));
    VWB_EXPECT(is_unicode_scalar(0xd7ff));
    VWB_EXPECT(!is_unicode_scalar(0xd800));
    VWB_EXPECT(!is_unicode_scalar(0xdfff));
    VWB_EXPECT(is_unicode_scalar(0xe000));
    VWB_EXPECT(is_unicode_scalar(0x10ffff));
    VWB_EXPECT(!is_unicode_scalar(0x110000));
    VWB_EXPECT_EQ(2166136261U, legacy_seed_hash({}));
    VWB_EXPECT_EQ(440920331U, legacy_seed_hash({'a', 'b', 'c'}));
    VWB_EXPECT_EQ(2327381698U, legacy_seed_hash({0x00e9U, 0x1f332U}));
    VWB_EXPECT_THROW(std::invalid_argument, legacy_seed_hash({0xd800U}));
}

VWB_TEST(sha256_matches_independent_standard_vectors_and_error_paths) {
    VWB_EXPECT_EQ(std::string("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), sha256_hex(sha256(nullptr, 0)));
    const std::vector<std::uint8_t> abc = {'a', 'b', 'c'};
    VWB_EXPECT_EQ(std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), sha256_hex(sha256(abc)));
    const std::string long_text = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const auto *long_bytes = reinterpret_cast<const std::uint8_t *>(long_text.data());
    VWB_EXPECT_EQ(std::string("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"), sha256_hex(sha256(long_bytes, long_text.size())));
    VWB_EXPECT_THROW(std::invalid_argument, sha256(nullptr, 1));
    const std::uint8_t dummy = 0;
    VWB_EXPECT_THROW(std::length_error, sha256(&dummy, std::numeric_limits<std::size_t>::max()));
}

namespace {

std::string bytes_hex(const std::vector<std::uint8_t> &bytes) {
    static constexpr char HEX[] = "0123456789abcdef";
    std::string result;
    result.reserve(bytes.size() * 2U);
    for (const std::uint8_t byte : bytes) {
        result.push_back(HEX[byte >> 4U]);
        result.push_back(HEX[byte & 0x0fU]);
    }
    return result;
}

SourceIdentity example_source() {
    return legacy_frozen_source_identity({'a', 't', 'l', 'a', 's', '-', '1', '4', '9', '2'});
}

} // namespace

VWB_TEST(source_identity_is_canonical_sorted_and_code_point_exact) {
    SourceIdentity source = example_source();
    const CanonicalIdentity first = canonical_source_identity(source);
    std::reverse(source.recipe_revisions.begin(), source.recipe_revisions.end());
    const CanonicalIdentity reordered = canonical_source_identity(source);
    VWB_EXPECT_EQ(first.bytes, reordered.bytes);
    VWB_EXPECT_EQ(first.digest, reordered.digest);
    VWB_EXPECT_EQ(first.digest_hex(), sha256_hex(first.digest));
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('V'), first.bytes[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('W'), first.bytes[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('B'), first.bytes[2]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('K'), first.bytes[3]);

    source.seed_code_points = {0x00e9U, 0x1f332U};
    const CanonicalIdentity unicode = canonical_source_identity(source);
    VWB_EXPECT(!(unicode.digest == first.digest));
    source.seed_code_points = {0xd800U};
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source = example_source();
    source.world_generator_binding.clear();
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
}

VWB_TEST(frozen_source_fixture_contains_the_complete_n0_version_map) {
    const SourceIdentity source = example_source();
    VWB_EXPECT_EQ(std::string("legacy-preservation-tree/cfcc96f2ebcb6a4c171cd37aca52fff6b65a6d8e"), source.world_generator_binding);
    VWB_EXPECT_EQ(static_cast<std::size_t>(15), source.recipe_revisions.size());
    VWB_EXPECT_EQ(static_cast<std::size_t>(8), source.world_constants.size());
    VWB_EXPECT_EQ(2U, source.biome_field_revision);
    VWB_EXPECT_EQ(1U, source.terrain_delta_schema_revision);
    VWB_EXPECT_EQ(2U, source.save_envelope_revision);
    VWB_EXPECT_EQ(std::string("building.interior_program"), source.recipe_revisions.front().name);
    VWB_EXPECT_EQ(2U, source.recipe_revisions.front().revision);
    VWB_EXPECT_EQ(std::string("tree.spawn"), source.recipe_revisions.back().name);
    VWB_EXPECT_EQ(10U, source.recipe_revisions.back().revision);
    VWB_EXPECT_EQ(1769472797U, legacy_seed_hash(source.seed_code_points));
    const CanonicalIdentity canonical = canonical_source_identity(source);
    VWB_EXPECT_EQ(static_cast<std::size_t>(743), canonical.bytes.size());
    VWB_EXPECT_EQ(std::string("5657424b010000000a00000061000000740000006c00000061000000730000002d000000310000003400000039000000320000001d037869410000006c65676163792d707265736572766174696f6e2d747265652f63666363393666326562636236613463313731636433376163613532666666366236356136643865020000000f000000190000006275696c64696e672e696e746572696f725f70726f6772616d020000001c0000006275696c64696e672e6e617669676174696f6e5f6d616e696665737409000000180000006275696c64696e672e7465727261696e5f70726f66696c6501000000190000006369746164656c2e67656e65726174696f6e5f706f6c69637901000000120000006369746164656c2e736974655f6669656c6401000000150000006369746164656c2e7375727665795f706f6c6963790100000013000000636f757274796172642e706c6163656d656e74010000001e0000006675726e697368696e672e6e617669676174696f6e5f6d616e6966657374020000000f0000006c616e646d61726b2e7265636970650100000015000000746f776e2e72756e74696d655f6d616e6966657374010000000e000000747265652e62757368795f6f616b150000000c000000747265652e636f6e696665720200000017000000747265652e70726f6365647572616c5f6772616d6d6172020000000c000000747265652e736176616e6e61020000000a000000747265652e737061776e0a0000000200000001000000080000000400000043454c4c029a9999999999f53f0a0000004348554e4b5f53495a45011c0000000a0000004d41585f484549474854020000000000005e400a0000004d494e5f4845494748540200000000000010400c00000053454354494f4e5f53495a45011000000011000000544f574e5f524547494f4e5f43454c4c5301180100000b00000057415445525f4c4556454c02333333333333264013000000574f524c445f424f54544f4d5f43454c4c5f5901c0ffffff"), bytes_hex(canonical.bytes));
    VWB_EXPECT_EQ(std::string("abbd66bd21010fe6f0a4b9406264fdefefa05bc793ed8a27ce2c7c59424736bf"), canonical.digest_hex());
}

VWB_TEST(source_identity_rejects_bad_recipe_names_and_duplicates) {
    SourceIdentity source = example_source();
    source.recipe_revisions = {{"same", 1}, {"same", 2}};
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source.recipe_revisions = {{"", 1}};
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    const std::array<std::string, 16> invalid_utf8 = {
        std::string("\xc0\x80", 2), std::string("\xe0\x80\x80", 3), std::string("\xed\xa0\x80", 3),
        std::string("\xf0\x80\x80\x80", 4), std::string("\xf4\x90\x80\x80", 4),
        std::string("\xe2\x82", 2), std::string("\xf0\x9f\x8c", 3), std::string("\x80", 1),
        std::string("\xc2", 1), std::string("\xc2\x41", 2),
        std::string("\xe1\x41\x80", 3), std::string("\xe1\x80\x41", 3),
        std::string("\xf1\x41\x80\x80", 4), std::string("\xf1\x80\x41\x80", 4),
        std::string("\xf1\x80\x80\x41", 4),
        std::string("\xf5\x80\x80\x80", 4),
    };
    for (const std::string &name : invalid_utf8) {
        source.recipe_revisions = {{name, 1}};
        VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    }
    source.recipe_revisions = {
        {std::string("\xc2\x80", 2), 1}, {std::string("\xdf\xbf", 2), 2},
        {std::string("\xe0\xa0\x80", 3), 3}, {std::string("\xed\x9f\xbf", 3), 4},
        {std::string("\xef\xbf\xbf", 3), 5}, {std::string("\xf0\x90\x80\x80", 4), 6},
        {std::string("\xf1\x80\x80\x80", 4), 7}, {std::string("\xf4\x8f\xbf\xbf", 4), 8},
    };
    VWB_EXPECT(!canonical_source_identity(source).bytes.empty());
}

VWB_TEST(source_identity_constants_are_typed_sorted_and_complete) {
    SourceIdentity source = example_source();
    const auto ordered = canonical_source_identity(source);
    std::reverse(source.world_constants.begin(), source.world_constants.end());
    VWB_EXPECT_EQ(ordered.bytes, canonical_source_identity(source).bytes);
    VWB_EXPECT_EQ(ConstantEncoding::signed_int32, source.world_constants.front().encoding);

    source.world_constants.push_back(source.world_constants.front());
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source = example_source();
    source.world_constants.front().name.clear();
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source = example_source();
    source.world_constants.front().encoding = static_cast<ConstantEncoding>(99);
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source = example_source();
    source.world_constants[1].bits = 0x100000000ULL;
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source = example_source();
    source.world_constants[0] = {"CELL", ConstantEncoding::ieee754_binary64, 0x7ff0000000000000ULL};
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    source = example_source();
    source.world_constants.pop_back();
    VWB_EXPECT_THROW(std::invalid_argument, canonical_source_identity(source));
    VWB_EXPECT_THROW(std::invalid_argument, binary64_constant("bad", std::numeric_limits<double>::infinity()));
    VWB_EXPECT_THROW(std::invalid_argument, binary64_constant("bad", std::numeric_limits<double>::quiet_NaN()));
    VWB_EXPECT_EQ(17U, canonical_u32_length(17));
    VWB_EXPECT_THROW(std::length_error, canonical_u32_length(0x100000000ULL));
}

VWB_TEST(snapshot_identity_binds_source_region_revisions_and_owner) {
    const CanonicalIdentity source = canonical_source_identity(example_source());
    SnapshotIdentity snapshot{source.digest, {{-16, -64, -16}, {16, 128, 16}}, {1, 4}, {9}, 7};
    const CanonicalIdentity first = canonical_snapshot_identity(snapshot);
    VWB_EXPECT_EQ(std::string("5657534e0100000020000000abbd66bd21010fe6f0a4b9406264fdefefa05bc793ed8a27ce2c7c59424736bff0ffffffc0fffffff0ffffff10000000800000001000000002000000010000000000000004000000000000000100000009000000000000000700000000000000"), bytes_hex(first.bytes));
    VWB_EXPECT_EQ(std::string("c44d61d3d04f16518b14d27bb114862a00ee2f9ddcfbeee628e24d057fc8101e"), first.digest_hex());
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('V'), first.bytes[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('W'), first.bytes[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('S'), first.bytes[2]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('N'), first.bytes[3]);
    snapshot.owner_generation = 8;
    VWB_EXPECT(!(canonical_snapshot_identity(snapshot).digest == first.digest));
    snapshot.region.maximum_exclusive.x = snapshot.region.minimum.x;
    VWB_EXPECT_THROW(std::invalid_argument, canonical_snapshot_identity(snapshot));
    snapshot.region.maximum_exclusive = {16, snapshot.region.minimum.y, 16};
    VWB_EXPECT_THROW(std::invalid_argument, canonical_snapshot_identity(snapshot));
    snapshot.region.maximum_exclusive = {16, 128, snapshot.region.minimum.z};
    VWB_EXPECT_THROW(std::invalid_argument, canonical_snapshot_identity(snapshot));
}

VWB_TEST(artifact_identity_binds_snapshot_kind_builder_detail_and_policies) {
    const CanonicalIdentity source = canonical_source_identity(example_source());
    const CanonicalIdentity snapshot = canonical_snapshot_identity({source.digest, {{-16, -64, -16}, {16, 128, 16}}, {1, 4}, {9}, 7});
    ArtifactIdentity artifact{snapshot.digest, ArtifactKind::terrain_collision, 4, 5, 0, "density+material", "half-open-owner", "one-cell-both-sides"};
    const CanonicalIdentity first = canonical_artifact_identity(artifact);
    VWB_EXPECT_EQ(std::string("565741520100000020000000c44d61d3d04f16518b14d27bb114862a00ee2f9ddcfbeee628e24d057fc8101e020400000005000000000000001000000064656e736974792b6d6174657269616c0f00000068616c662d6f70656e2d6f776e6572130000006f6e652d63656c6c2d626f74682d7369646573"), bytes_hex(first.bytes));
    VWB_EXPECT_EQ(std::string("d324b63f9d0e30bf6c43bb3fe6705e31966d3b04ad13f0fb3093f84f4a997a83"), first.digest_hex());
    for (const ArtifactKind kind : {ArtifactKind::terrain_source, ArtifactKind::terrain_collision, ArtifactKind::terrain_render, ArtifactKind::navigation_support}) {
        artifact.kind = kind;
        VWB_EXPECT(!canonical_artifact_identity(artifact).bytes.empty());
    }
    artifact.lod_level = 1;
    VWB_EXPECT(!(canonical_artifact_identity(artifact).digest == first.digest));
    artifact.kind = static_cast<ArtifactKind>(99);
    VWB_EXPECT_THROW(std::invalid_argument, canonical_artifact_identity(artifact));
    artifact.kind = ArtifactKind::terrain_collision;
    artifact.builder_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, canonical_artifact_identity(artifact));
    artifact.builder_revision = 1;
    artifact.channel_policy.clear();
    VWB_EXPECT_THROW(std::invalid_argument, canonical_artifact_identity(artifact));
    artifact.channel_policy = "density";
    artifact.seam_policy.clear();
    VWB_EXPECT_THROW(std::invalid_argument, canonical_artifact_identity(artifact));
    artifact.seam_policy = "half-open";
    artifact.halo_policy.clear();
    VWB_EXPECT_THROW(std::invalid_argument, canonical_artifact_identity(artifact));
}

VWB_TEST(authority_tokens_reject_wrong_world_owner_epoch_and_revision) {
    RequestAuthority current{};
    current.world_digest[0] = 1;
    current.owner.value = 2;
    current.cancellation.value = 3;
    current.source_revision.value = 4;
    RequestAuthority result = current;
    VWB_EXPECT_EQ(AuthorityDecision::accept, validate_result_authority(result, current));
    result.world_digest[0] = 9;
    VWB_EXPECT_EQ(AuthorityDecision::wrong_world, validate_result_authority(result, current));
    result = current;
    result.owner.value = 9;
    VWB_EXPECT_EQ(AuthorityDecision::stale_owner, validate_result_authority(result, current));
    result = current;
    result.cancellation.value = 9;
    VWB_EXPECT_EQ(AuthorityDecision::cancelled, validate_result_authority(result, current));
    result = current;
    result.source_revision.value = 9;
    VWB_EXPECT_EQ(AuthorityDecision::stale_source, validate_result_authority(result, current));

    CancellationEpoch epoch{0};
    VWB_EXPECT(advance_epoch(epoch));
    VWB_EXPECT_EQ(1ULL, epoch.value);
    epoch.value = std::numeric_limits<std::uint64_t>::max();
    VWB_EXPECT(!advance_epoch(epoch));
    OwnerGeneration owner{0};
    VWB_EXPECT(advance_owner(owner));
    VWB_EXPECT_EQ(1ULL, owner.value);
    owner.value = std::numeric_limits<std::uint64_t>::max();
    VWB_EXPECT(!advance_owner(owner));
}
