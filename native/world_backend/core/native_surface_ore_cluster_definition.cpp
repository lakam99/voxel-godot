#include "native_surface_ore_cluster_definition.hpp"

#include <cmath>
#include <cstring>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceOreClusterDefinitionRejected(); }

constexpr double TAU = 6.28318530717958647692;

float f32(double value) { return static_cast<float>(value); }

WorldFloat32Position vec(double x, double y, double z) { return {f32(x), f32(y), f32(z)}; }

float sum(float a, float b) { return f32(static_cast<double>(a) + static_cast<double>(b)); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i32(std::int32_t v) { u32(static_cast<std::uint32_t>(v)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i64(std::int64_t v) { u64(static_cast<std::uint64_t>(v)); }
    void digest(const Sha256Digest &d) { bytes.insert(bytes.end(), d.begin(), d.end()); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void f32bits(float v) { std::uint32_t b; std::memcpy(&b, &v, sizeof(b)); u32(b); }
    void f64bits(double v) { std::uint64_t b; std::memcpy(&b, &v, sizeof(b)); u64(b); }
    void position(const WorldFloat32Position &v) { f32bits(v.x); f32bits(v.y); f32bits(v.z); }
    std::vector<std::uint8_t> bytes;
};

void write_child(Writer &w, const NativeSurfaceOreChildDefinition &c,
    const NativeOreClusterChildStream &source) {
    w.u32(c.child_index); w.text(c.durable_id); w.u8(c.present ? 1U : 0U);
    w.u64(c.state_before); w.u64(c.state_after); w.i64(c.drop_count);
    w.u32(static_cast<std::uint32_t>(source.float_draws.size()));
    for (float draw : source.float_draws) w.f32bits(draw);
    w.position(c.local_position); w.position(c.world_anchor); w.f32bits(c.rotation_y);
    w.f64bits(c.radius); w.f32bits(c.mesh_radius); w.f32bits(c.mesh_height);
    w.i32(c.mesh_radial_segments); w.i32(c.mesh_rings); w.f32bits(c.mesh_center_y);
    w.position(c.mesh_scale); w.position(c.seam_mesh_size);
    for (const auto &seam : c.seams) { w.position(seam.local_position); w.position(seam.rotation); }
    w.f32bits(c.glint_mesh_radius); w.f32bits(c.glint_mesh_height);
    w.i32(c.glint_radial_segments); w.i32(c.glint_rings);
    for (const auto &glint : c.glints) { w.position(glint.local_position); w.position(glint.scale); }
    w.f32bits(c.collider_radius); w.f32bits(c.collider_center_y);
}

} // namespace

NativeSurfaceOreClusterDefinitionRejected::NativeSurfaceOreClusterDefinitionRejected()
    : std::invalid_argument("invalid native surface ore-cluster definition") {}

void validate_native_surface_ore_attempt_receipts(const NativeSurfacePropOrderedAttempt &attempt) {
    if (!attempt.ore_cluster || !attempt.prop_roll || !attempt.ore_roll) reject();
}

NativeSurfaceOreChildDefinition decode_native_surface_ore_child(
    const NativeOreClusterChildStream &child, const std::uint32_t child_index,
    const NativeSurfacePropPlacementEntry &root, const NativeOreKind kind) {
    if (child_index >= 2U || (kind != NativeOreKind::iron && kind != NativeOreKind::copper)
        || root.presence != NativeSurfacePropPlacementPresence::anchored
        || child.durable_id != (child_index == 0U ? root.durable_id : root.durable_id + ":cluster1")) reject();
    NativeSurfaceOreChildDefinition out;
    out.child_index = child_index; out.durable_id = child.durable_id;
    out.state_before = child.state_before; out.state_after = child.state_after;
    if (child.skipped_by_tombstone) {
        if (!child.float_draws.empty() || child.drop_count != 0 || child.state_before != child.state_after) reject();
        return out;
    }
    if (child.float_draws.size() != (child_index == 0U ? 47U : 48U)
        || child.drop_count < 1 || child.drop_count > (kind == NativeOreKind::iron ? 2 : 3)) reject();
    for (float draw : child.float_draws) if (!std::isfinite(draw) || draw < 0.0F || draw >= 1.0F) reject();
    out.present = true; out.drop_count = child.drop_count;
    const auto &d = child.float_draws;
    std::size_t i = 0U;
    const double angle = static_cast<double>(d[i++]) * TAU
        + static_cast<double>(child_index) * TAU / 2.0;
    const double spacing = child_index == 0U ? 0.0
        : 1.35 * (0.60 + static_cast<double>(d[i++]) * 0.42);
    const auto offset = vec(std::cos(angle) * spacing,
        static_cast<double>(d[i++]) * 0.08, std::sin(angle) * spacing);
    out.local_position = {sum(root.local_position.x, offset.x),
        sum(root.local_position.y, offset.y), sum(root.local_position.z, offset.z)};
    out.world_anchor = {sum(root.chunk_origin.x, out.local_position.x),
        out.local_position.y, sum(root.chunk_origin.z, out.local_position.z)};
    out.rotation_y = f32(static_cast<double>(d[i++]) * TAU);
    out.radius = 0.58 + static_cast<double>(d[i++]) * 0.82;
    out.mesh_radius = f32(out.radius);
    out.mesh_height = f32(out.radius * (0.70 + static_cast<double>(d[i++]) * 0.56));
    out.mesh_radial_segments = 9;
    out.mesh_rings = 5;
    out.mesh_center_y = f32(out.radius * 0.40);
    const double scale_x_draw = d[i++];
    const double scale_y_draw = d[i++];
    const double scale_z_draw = d[i++];
    out.mesh_scale = vec(1.15 + scale_x_draw * 0.5,
        0.62 + scale_y_draw * 0.45, 1.0 + scale_z_draw * 0.42);
    out.seam_mesh_size = vec(out.radius * 0.78, out.radius * 0.12, out.radius * 0.18);
    for (auto &seam : out.seams) {
        const double px = d[i++]; const double py = d[i++]; const double pz = d[i++];
        const double rx = d[i++]; const double ry = d[i++]; const double rz = d[i++];
        seam.local_position = vec((px - 0.5) * out.radius * 0.95,
            out.radius * (0.38 + py * 0.48), -out.radius * (0.44 + pz * 0.18));
        seam.rotation = vec(rx * 0.7, ry * TAU, rz * 0.7);
    }
    out.glint_mesh_radius = f32(out.radius * 0.13);
    out.glint_mesh_height = f32(out.radius * 0.18);
    out.glint_radial_segments = 6;
    out.glint_rings = 3;
    for (auto &glint : out.glints) {
        const double px = d[i++]; const double py = d[i++]; const double sy = d[i++];
        glint.local_position = vec((px - 0.5) * out.radius * 0.72,
            out.radius * (0.58 + py * 0.28), -out.radius * 0.58);
        glint.scale = vec(1.0, 0.72 + sy * 0.38, 1.0);
    }
    out.collider_radius = f32(out.radius * 1.05);
    out.collider_center_y = f32(out.radius * 0.42);
    if (!std::isfinite(out.world_anchor.x) || !std::isfinite(out.world_anchor.y)
        || !std::isfinite(out.world_anchor.z)) reject();
    return out;
}

NativeSurfaceOreClusterDefinition NativeSurfaceOreClusterDefinition::create(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    const std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || !ordered.source_receipt().matches_pin(terrain.pin())) reject();
    if (NativeSurfacePropOrderedPlacement::create(ordered, terrain).content_digest()
        != placements.content_digest()) reject();
    const auto &attempt = ordered.attempts()[ordinal];
    const auto &root = placements.entries()[ordinal];
    NativeOreKind kind;
    if (attempt.outcome == NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster)
        kind = NativeOreKind::iron;
    else if (attempt.outcome == NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster)
        kind = NativeOreKind::copper;
    else reject();
    validate_native_surface_ore_attempt_receipts(attempt);
    // The private stream producer emits a cluster for each ore outcome and
    // owns child/state continuity. Recomputed SPO1 proves root alignment.
    NativeSurfaceOreClusterDefinition out;
    out.kind_ = kind; out.ordinal_ = ordinal; out.root_durable_id_ = root.durable_id;
    for (std::uint32_t child = 0U; child < 2U; ++child)
        out.children_[child] = decode_native_surface_ore_child(
            attempt.ore_cluster->children()[child], child, root, kind);
    Writer w;
    w.u8('S'); w.u8('O'); w.u8('C'); w.u8('1'); w.u32(SCHEMA_REVISION);
    w.digest(ordered.world_digest()); w.u64(ordered.world_generation());
    w.i32(ordered.chunk_x()); w.i32(ordered.chunk_z()); w.digest(ordered.exclusion_digest());
    w.u32(ordered.source_receipt().schema_revision);
    w.digest(ordered.source_receipt().effective_source_digest);
    w.u64(ordered.source_receipt().terrain_delta_revision);
    w.u64(ordered.source_receipt().shaping_registry_revision);
    w.u32(ordered.source_receipt().environment_profile_revision);
    w.digest(ordered.source_receipt().environment_profile_digest);
    w.digest(terrain.pin().physical_content_identity().digest);
    w.digest(terrain.pin().definition().physical_content_identity().digest);
    w.digest(placements.content_digest());
    w.u32(ordinal); w.text(root.durable_id); w.digest(root.source_decision_digest);
    w.u8(static_cast<std::uint8_t>(kind));
    w.u32(ordered.rng_seed()); w.u64(ordered.final_rng_state());
    w.u64(attempt.state_before_coordinates); w.u64(attempt.state_after_coordinates);
    // The private ordered producer emits both rolls for an ore outcome and
    // no generic compatibility draws; child draws are written below.
    w.f32bits(*attempt.prop_roll); w.f32bits(*attempt.ore_roll);
    w.u64(attempt.state_after_classification); w.u64(attempt.state_after_recipe);
    for (std::size_t child = 0U; child < 2U; ++child)
        write_child(w, out.children_[child], attempt.ore_cluster->children()[child]);
    out.canonical_binary_ = std::move(w.bytes);
    out.content_digest_ = sha256(out.canonical_binary_);
    return out;
}

NativeOreKind NativeSurfaceOreClusterDefinition::kind() const noexcept { return kind_; }
std::uint32_t NativeSurfaceOreClusterDefinition::ordinal() const noexcept { return ordinal_; }
const std::string &NativeSurfaceOreClusterDefinition::root_durable_id() const noexcept { return root_durable_id_; }
const std::array<NativeSurfaceOreChildDefinition, 2> &NativeSurfaceOreClusterDefinition::children() const noexcept {
    return children_;
}
const std::vector<std::uint8_t> &NativeSurfaceOreClusterDefinition::canonical_binary() const noexcept {
    return canonical_binary_;
}
const Sha256Digest &NativeSurfaceOreClusterDefinition::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
