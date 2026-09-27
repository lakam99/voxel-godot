#include "native_collision_artifact.hpp"

#include <atomic>
#include <cmath>
#include <exception>
#include <limits>
#include <new>
#include <stdexcept>
#include <thread>
#include <utility>

namespace voxel::world_backend {
namespace artifact_detail {
constexpr std::size_t absent = std::numeric_limits<std::size_t>::max();
enum class Kind : std::uint8_t { session, builder, artifact, role, transfer, hold };
struct Header { std::size_t requested, alignment; };
struct Base { std::size_t refs, next; std::uint64_t cookie; bool occupied; };
struct SessionSlot { Base base; ArtifactOwnerKind kind; bool closed; };
struct ArtifactSlot {
    Base base;
    ArtifactSourceStamp stamp;
    ArtifactTriangle *triangles;
    void *scratch;
    std::size_t output_bytes, scratch_bytes, count, capacity, owner_session;
    std::uint64_t owner_session_cookie, owner_epoch, pending_cookie, pending_epoch;
    bool sealed, cancelled, builder_session_edge;
};
struct RoleSlot {
    Base base;
    std::size_t artifact, session;
    std::uint64_t artifact_cookie, session_cookie, epoch;
    bool released;
};
enum class TransferState : std::uint8_t { staged, committed, aborted };
struct TransferSlot {
    Base base;
    std::size_t origin_role, destination_role, destination_session, artifact;
    std::uint64_t artifact_cookie, origin_epoch;
    TransferState state;
    bool invalidated;
};
struct HoldSlot { Base base; std::size_t artifact; std::uint64_t artifact_cookie; };
struct Credit { std::size_t next; bool occupied; };
template<class T> struct Pool { T *items; std::size_t capacity, free, occupied; };
struct Control {
    ArtifactDomainConfig config;
    ArtifactAllocationPolicy policy;
    std::thread::id owner;
    Pool<SessionSlot> sessions;
    Pool<ArtifactSlot> artifacts;
    Pool<RoleSlot> roles;
    Pool<TransferSlot> transfers;
    Pool<HoldSlot> holds;
    Credit *credits;
    std::size_t free_credit, live_tokens, refs, used, peak, reserved, fixed, ordinal, cursor;
    std::uint64_t next_cookie;
    bool closed;
};
std::atomic<std::size_t> global_bytes{0}, global_blocks{0}, global_allocations{0}, global_deallocations{0};

std::size_t add(std::size_t a, std::size_t b) {
    if (b > std::numeric_limits<std::size_t>::max() - a) throw std::overflow_error("artifact size addition");
    return a + b;
}
std::size_t multiply(std::size_t a, std::size_t b) {
    if (a && b > std::numeric_limits<std::size_t>::max() / a) throw std::overflow_error("artifact size multiplication");
    return a * b;
}
void alignment_valid(std::size_t a) {
    if (a < alignof(std::max_align_t) || (a & (a - 1))) throw std::invalid_argument("artifact allocation alignment");
}
std::size_t aligned(std::size_t n, std::size_t a) { return add(n, a - 1) & ~(a - 1); }
std::size_t requested(std::size_t n, std::size_t a) {
    alignment_valid(a);
    return add(aligned(sizeof(Header), a), aligned(n, a));
}
void *allocate_raw(std::size_t n, std::size_t a) {
    const auto bytes = requested(n, a);
    auto *base = static_cast<unsigned char *>(::operator new(bytes, std::align_val_t(a)));
    new (base) Header{bytes, a};
    global_bytes.fetch_add(bytes, std::memory_order_relaxed);
    global_blocks.fetch_add(1, std::memory_order_relaxed);
    global_allocations.fetch_add(1, std::memory_order_relaxed);
    return base + aligned(sizeof(Header), a);
}
void free_raw(void *payload, std::size_t a) noexcept {
    if (!payload) return;
    auto *base = static_cast<unsigned char *>(payload) - aligned(sizeof(Header), a);
    auto *header = reinterpret_cast<Header *>(base);
    global_bytes.fetch_sub(header->requested, std::memory_order_relaxed);
    global_blocks.fetch_sub(1, std::memory_order_relaxed);
    global_deallocations.fetch_add(1, std::memory_order_relaxed);
    header->~Header();
    ::operator delete(base, std::align_val_t(a));
}
bool owner(const Control *c) noexcept { return c && c->owner == std::this_thread::get_id(); }
void owner_or_die(const Control *c) noexcept { if (c && !owner(c)) std::terminate(); }
void keep(Control *c) noexcept {
    if (c->refs == std::numeric_limits<std::size_t>::max()) std::terminate();
    ++c->refs;
}
void drop(Control *c) noexcept {
    if (--c->refs) return;
    // Every occupied slot has an external token or a counted acyclic edge.
    // Thus the last control release never scans or discovers live backings.
    if (c->sessions.occupied || c->artifacts.occupied || c->roles.occupied
        || c->transfers.occupied || c->holds.occupied || c->live_tokens || c->reserved) std::terminate();
    const auto a = c->config.allocation_alignment;
    c->~Control();
    free_raw(c, a);
}
template<class T> void initialize(Pool<T> &p, unsigned char *memory, std::size_t count) {
    p = {reinterpret_cast<T *>(memory), count, count ? 0 : absent, 0};
    for (std::size_t i = 0; i != count; ++i) {
        new (p.items + i) T{};
        p.items[i].base.next = i + 1 == count ? absent : i + 1;
    }
}
template<class T> std::size_t region(std::size_t &offset, std::size_t count) {
    offset = aligned(offset, alignof(T));
    const auto start = offset;
    offset = add(offset, multiply(count, sizeof(T)));
    return start;
}
template<class T> std::size_t open(Pool<T> &p, std::uint64_t cookie) noexcept {
    const auto i = p.free;
    p.free = p.items[i].base.next;
    p.items[i] = T{};
    p.items[i].base = {0, absent, cookie, true};
    ++p.occupied;
    return i;
}
template<class T> void recycle(Pool<T> &p, std::size_t i) noexcept {
    p.items[i].base.occupied = false;
    p.items[i].base.next = p.free;
    p.free = i;
    --p.occupied;
}
ArtifactReason next_cookie(Control &c, std::uint64_t &out) noexcept {
    if (c.next_cookie == std::numeric_limits<std::uint64_t>::max()) return ArtifactReason::cookie_exhausted;
    out = c.next_cookie++;
    return ArtifactReason::none;
}
bool room(const Control &c, const Base &base, std::size_t n = 1) noexcept {
    return n <= c.config.maximum_references && base.refs <= c.config.maximum_references - n;
}
Base *base(Control &c, Kind k, std::size_t i) noexcept {
    switch (k) {
        case Kind::session: return i < c.sessions.capacity ? &c.sessions.items[i].base : nullptr;
        case Kind::builder:
        case Kind::artifact: return i < c.artifacts.capacity ? &c.artifacts.items[i].base : nullptr;
        case Kind::role: return i < c.roles.capacity ? &c.roles.items[i].base : nullptr;
        case Kind::transfer: return i < c.transfers.capacity ? &c.transfers.items[i].base : nullptr;
        case Kind::hold: return i < c.holds.capacity ? &c.holds.items[i].base : nullptr;
    }
    return nullptr;
}
void release_slot(Control &c, Kind k, std::size_t i) noexcept;
void clear_pending(Control &c, const TransferSlot &t) noexcept {
    auto &a = c.artifacts.items[t.artifact];
    if (a.base.occupied && a.base.cookie == t.artifact_cookie
        && a.pending_cookie == t.base.cookie && a.pending_epoch == t.origin_epoch) {
        a.pending_cookie = 0;
        a.pending_epoch = 0;
    }
}
void release_slot(Control &c, Kind k, std::size_t i) noexcept {
    auto *b = base(c, k, i);
    if (!b || !b->occupied || !b->refs) std::terminate();
    if (--b->refs) return;
    switch (k) {
        case Kind::session: recycle(c.sessions, i); break;
        case Kind::builder:
        case Kind::artifact: {
            auto &a = c.artifacts.items[i];
            if (a.builder_session_edge) release_slot(c, Kind::session, a.owner_session);
            c.used -= a.output_bytes + a.scratch_bytes;
            free_raw(a.triangles, c.config.allocation_alignment);
            free_raw(a.scratch, c.config.allocation_alignment);
            recycle(c.artifacts, i);
            break;
        }
        case Kind::role: {
            const auto r = c.roles.items[i];
            recycle(c.roles, i);
            release_slot(c, Kind::artifact, r.artifact);
            release_slot(c, Kind::session, r.session);
            break;
        }
        case Kind::hold: {
            const auto h = c.holds.items[i];
            recycle(c.holds, i);
            release_slot(c, Kind::artifact, h.artifact);
            break;
        }
        case Kind::transfer: {
            const auto t = c.transfers.items[i];
            clear_pending(c, t);
            recycle(c.transfers, i);
            // Two roles share exactly one artifact. Three session-edge drops
            // reach at most two unique sessions; there is no owning back edge.
            release_slot(c, Kind::role, t.origin_role);
            release_slot(c, Kind::role, t.destination_role);
            release_slot(c, Kind::session, t.destination_session);
            break;
        }
    }
}
template<class Tag> Kind kind();
template<> Kind kind<ArtifactSessionTag>() { return Kind::session; }
template<> Kind kind<ArtifactBuilderTag>() { return Kind::builder; }
template<> Kind kind<CollisionArtifactTag>() { return Kind::artifact; }
template<> Kind kind<ArtifactRoleTag>() { return Kind::role; }
template<> Kind kind<ArtifactTransferTag>() { return Kind::transfer; }
template<> Kind kind<ArtifactHoldTag>() { return Kind::hold; }

struct Access {
    template<class Tag> static ArtifactReason check(Control *c, const ArtifactToken<Tag> &t) noexcept {
        if (!owner(c)) return c ? ArtifactReason::wrong_thread : ArtifactReason::closed;
        if (!t.control_ || t.control_ != c) return ArtifactReason::foreign_token;
        auto *b = base(*c, kind<Tag>(), t.slot_);
        if (!b || !b->occupied || b->cookie != t.cookie_ || !b->refs) return ArtifactReason::stale_token;
        return ArtifactReason::none;
    }
    template<class Tag> static std::size_t index(const ArtifactToken<Tag> &t) noexcept { return t.slot_; }
    template<class Tag> static ArtifactToken<Tag> issue(Control &c, std::size_t i) noexcept {
        auto *b = base(c, kind<Tag>(), i);
        const auto credit = c.free_credit;
        c.free_credit = c.credits[credit].next;
        c.credits[credit].occupied = true;
        ++c.live_tokens;
        ++b->refs;
        keep(&c);
        ArtifactToken<Tag> t;
        t.control_ = &c; t.slot_ = i; t.credit_ = credit; t.cookie_ = b->cookie;
        return t;
    }
    template<class Tag> static void reset(ArtifactToken<Tag> &t) noexcept {
        auto *c = t.control_;
        if (!c) return;
        owner_or_die(c);
        keep(c); // The fixed-depth cascade must not destroy Control mid-edge.
        const auto slot = t.slot_, credit = t.credit_;
        t.control_ = nullptr; t.slot_ = absent; t.credit_ = absent; t.cookie_ = 0;
        c->credits[credit].occupied = false;
        c->credits[credit].next = c->free_credit; c->free_credit = credit;
        --c->live_tokens;
        release_slot(*c, kind<Tag>(), slot);
        drop(c); // Token's actual control reference.
        drop(c); // Cascade fence.
    }
    template<class To, class From> static ArtifactToken<To> convert(ArtifactToken<From> &old) noexcept {
        ArtifactToken<To> t;
        t.control_ = old.control_; t.slot_ = old.slot_; t.credit_ = old.credit_; t.cookie_ = old.cookie_;
        old.control_ = nullptr; old.slot_ = absent; old.credit_ = absent; old.cookie_ = 0;
        return t;
    }
};
template<class T> ArtifactResult<T> failed(ArtifactReason reason) {
    const bool pending = reason == ArtifactReason::capacity || reason == ArtifactReason::allocation_failed
        || reason == ArtifactReason::competing_transfer || reason == ArtifactReason::outstanding_holders;
    return {pending ? ArtifactStatus::pending : ArtifactStatus::rejected, reason, T{}};
}
ArtifactReason session_current(const Control &c, std::size_t i, std::uint64_t cookie) noexcept {
    if (c.closed) return ArtifactReason::closed;
    const auto &s = c.sessions.items[i];
    if (!s.base.occupied || s.base.cookie != cookie) return ArtifactReason::stale_token;
    return s.closed ? ArtifactReason::closed : ArtifactReason::none;
}
ArtifactReason artifact_current(const Control &c, const ArtifactSlot &a) noexcept {
    if (c.closed) return ArtifactReason::closed;
    if (a.cancelled) return ArtifactReason::cancelled;
    return session_current(c, a.owner_session, a.owner_session_cookie);
}
ArtifactReason role_current(const Control &c, const RoleSlot &r) noexcept {
    const auto &a = c.artifacts.items[r.artifact];
    if (r.released || !a.base.occupied || a.base.cookie != r.artifact_cookie
        || a.owner_epoch != r.epoch || a.owner_session != r.session) return ArtifactReason::stale_token;
    return artifact_current(c, a);
}
template<class Tag> ArtifactResult<ArtifactToken<Tag>> clone(Control *c, const ArtifactToken<Tag> &t, ArtifactReason extra) {
    auto why = Access::check(c, t);
    if (why != ArtifactReason::none) return failed<ArtifactToken<Tag>>(why);
    if (extra != ArtifactReason::none) return failed<ArtifactToken<Tag>>(extra);
    if (c->free_credit == absent) return failed<ArtifactToken<Tag>>(ArtifactReason::capacity);
    if (!room(*c, *base(*c, kind<Tag>(), Access::index(t)))) return failed<ArtifactToken<Tag>>(ArtifactReason::reference_exhausted);
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<Tag>(*c, Access::index(t))};
}
ArtifactAccounting accounting(const Control &c) noexcept {
    return {c.used, c.peak, c.reserved, c.fixed, c.used - c.fixed, c.sessions.occupied,
        c.artifacts.occupied, c.roles.occupied, c.transfers.occupied, c.holds.occupied,
        c.live_tokens, c.config.token_slots, c.live_tokens * sizeof(Credit), c.cursor,
        c.closed, c.artifacts.occupied == 0};
}
void *allocate_payload(Control &c, std::size_t bytes) {
    if (++c.ordinal == c.policy.fail_allocation_ordinal) throw std::bad_alloc();
    auto *p = allocate_raw(bytes, c.config.allocation_alignment);
    const auto q = requested(bytes, c.config.allocation_alignment);
    c.used += q; c.reserved -= q;
    return p;
}
bool triangle_finite(const ArtifactTriangle &t) noexcept {
    return std::isfinite(t.a.x) && std::isfinite(t.a.y) && std::isfinite(t.a.z)
        && std::isfinite(t.b.x) && std::isfinite(t.b.y) && std::isfinite(t.b.z)
        && std::isfinite(t.c.x) && std::isfinite(t.c.y) && std::isfinite(t.c.z);
}
}

using namespace artifact_detail;
template<class Tag> ArtifactToken<Tag>::ArtifactToken() noexcept : control_(nullptr), slot_(absent), credit_(absent), cookie_(0) {}
template<class Tag> ArtifactToken<Tag>::~ArtifactToken() noexcept { Access::reset(*this); }
template<class Tag> ArtifactToken<Tag>::ArtifactToken(ArtifactToken &&other) noexcept : ArtifactToken() {
    owner_or_die(other.control_);
    control_ = other.control_; slot_ = other.slot_; credit_ = other.credit_; cookie_ = other.cookie_;
    other.control_ = nullptr; other.slot_ = absent; other.credit_ = absent; other.cookie_ = 0;
}
template<class Tag> ArtifactToken<Tag> &ArtifactToken<Tag>::operator=(ArtifactToken &&other) noexcept {
    owner_or_die(control_); owner_or_die(other.control_);
    if (this != &other) {
        Access::reset(*this);
        control_ = other.control_; slot_ = other.slot_; credit_ = other.credit_; cookie_ = other.cookie_;
        other.control_ = nullptr; other.slot_ = absent; other.credit_ = absent; other.cookie_ = 0;
    }
    return *this;
}
template class ArtifactToken<ArtifactSessionTag>;
template class ArtifactToken<ArtifactBuilderTag>;
template class ArtifactToken<CollisionArtifactTag>;
template class ArtifactToken<ArtifactRoleTag>;
template class ArtifactToken<ArtifactTransferTag>;
template class ArtifactToken<ArtifactHoldTag>;

NativeCollisionArtifactDomain::NativeCollisionArtifactDomain(const ArtifactDomainConfig &cfg, ArtifactAllocationPolicy policy) : control_(nullptr) {
    alignment_valid(cfg.allocation_alignment);
    if (!cfg.byte_limit || cfg.byte_limit > byte_ceiling || !cfg.session_slots || !cfg.artifact_slots
        || !cfg.role_slots || !cfg.transfer_slots || !cfg.hold_slots || !cfg.token_slots || !cfg.maximum_references)
        throw std::invalid_argument("artifact configuration");
    std::size_t bytes = sizeof(Control);
    const auto so = region<SessionSlot>(bytes, cfg.session_slots);
    const auto ao = region<ArtifactSlot>(bytes, cfg.artifact_slots);
    const auto ro = region<RoleSlot>(bytes, cfg.role_slots);
    const auto to = region<TransferSlot>(bytes, cfg.transfer_slots);
    const auto ho = region<HoldSlot>(bytes, cfg.hold_slots);
    const auto co = region<Credit>(bytes, cfg.token_slots);
    const auto fixed = requested(bytes, cfg.allocation_alignment);
    if (fixed > cfg.byte_limit) throw std::invalid_argument("artifact fixed pools exceed byte limit");
    if (policy.fail_allocation_ordinal == 1) throw std::bad_alloc();
    auto *memory = static_cast<unsigned char *>(allocate_raw(bytes, cfg.allocation_alignment));
    auto *c = new (memory) Control{};
    c->config = cfg; c->policy = policy; c->owner = std::this_thread::get_id();
    initialize(c->sessions, memory + so, cfg.session_slots);
    initialize(c->artifacts, memory + ao, cfg.artifact_slots);
    initialize(c->roles, memory + ro, cfg.role_slots);
    initialize(c->transfers, memory + to, cfg.transfer_slots);
    initialize(c->holds, memory + ho, cfg.hold_slots);
    c->credits = reinterpret_cast<Credit *>(memory + co);
    for (std::size_t i = 0; i != cfg.token_slots; ++i) new (c->credits + i) Credit{i + 1 == cfg.token_slots ? absent : i + 1, false};
    c->free_credit = 0; c->refs = 1; c->used = c->peak = c->fixed = fixed; c->ordinal = 1; c->next_cookie = 1;
    control_ = c;
}
NativeCollisionArtifactDomain::~NativeCollisionArtifactDomain() noexcept {
    owner_or_die(control_);
    if (control_) { control_->closed = true; drop(control_); }
}
NativeCollisionArtifactDomain::NativeCollisionArtifactDomain(NativeCollisionArtifactDomain &&other) noexcept : control_(other.control_) {
    owner_or_die(control_); other.control_ = nullptr;
}
NativeCollisionArtifactDomain &NativeCollisionArtifactDomain::operator=(NativeCollisionArtifactDomain &&other) noexcept {
    owner_or_die(control_); owner_or_die(other.control_);
    if (this != &other) {
        if (control_) { control_->closed = true; drop(control_); }
        control_ = other.control_; other.control_ = nullptr;
    }
    return *this;
}
ArtifactResult<ArtifactSession> NativeCollisionArtifactDomain::issue_session(ArtifactOwnerKind k) {
    auto *c = control_;
    if (!owner(c)) return failed<ArtifactSession>(c ? ArtifactReason::wrong_thread : ArtifactReason::closed);
    if (c->closed) return failed<ArtifactSession>(ArtifactReason::closed);
    if (k != ArtifactOwnerKind::producer && k != ArtifactOwnerKind::broker && k != ArtifactOwnerKind::receiver)
        return failed<ArtifactSession>(ArtifactReason::wrong_owner);
    if (c->sessions.free == absent || c->free_credit == absent) return failed<ArtifactSession>(ArtifactReason::capacity);
    std::uint64_t cookie;
    const auto why = next_cookie(*c, cookie);
    if (why != ArtifactReason::none) return failed<ArtifactSession>(why);
    const auto i = open(c->sessions, cookie); c->sessions.items[i].kind = k;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<ArtifactSessionTag>(*c, i)};
}
ArtifactResult<ArtifactSession> NativeCollisionArtifactDomain::clone_session(const ArtifactSession &s) {
    auto why = Access::check(control_, s);
    if (why == ArtifactReason::none) why = session_current(*control_, Access::index(s), control_->sessions.items[Access::index(s)].base.cookie);
    return clone(control_, s, why);
}
ArtifactReason NativeCollisionArtifactDomain::close_session(const ArtifactSession &s) {
    const auto why = Access::check(control_, s);
    if (why != ArtifactReason::none) return why;
    control_->sessions.items[Access::index(s)].closed = true;
    return ArtifactReason::none;
}
ArtifactResult<ArtifactBuilder> NativeCollisionArtifactDomain::begin(const ArtifactSession &s, const ArtifactSourceStamp &stamp, const ArtifactReservation &r) {
    auto why = Access::check(control_, s);
    if (why != ArtifactReason::none) return failed<ArtifactBuilder>(why);
    auto &c = *control_; const auto si = Access::index(s); auto &session = c.sessions.items[si];
    why = session_current(c, si, session.base.cookie);
    if (why != ArtifactReason::none) return failed<ArtifactBuilder>(why);
    if (session.kind != ArtifactOwnerKind::producer) return failed<ArtifactBuilder>(ArtifactReason::wrong_owner);
    if (!stamp.incarnation || stamp.through_revision < stamp.original_revision) return failed<ArtifactBuilder>(ArtifactReason::invalid_configuration);
    if (c.artifacts.free == absent || c.free_credit == absent) return failed<ArtifactBuilder>(ArtifactReason::capacity);
    if (!room(c, session.base)) return failed<ArtifactBuilder>(ArtifactReason::reference_exhausted);
    std::size_t output_size, output_q, scratch_q, total;
    try {
        output_size = multiply(r.triangle_capacity, sizeof(ArtifactTriangle));
        output_q = output_size ? requested(output_size, c.config.allocation_alignment) : 0;
        scratch_q = r.scratch_capacity_bytes ? requested(r.scratch_capacity_bytes, c.config.allocation_alignment) : 0;
        total = add(output_q, scratch_q);
    } catch (const std::overflow_error &) { return failed<ArtifactBuilder>(ArtifactReason::size_overflow); }
    if (total > c.config.byte_limit - c.used - c.reserved) return failed<ArtifactBuilder>(ArtifactReason::capacity);
    std::uint64_t cookie;
    why = next_cookie(c, cookie); if (why != ArtifactReason::none) return failed<ArtifactBuilder>(why);
    const auto i = open(c.artifacts, cookie); auto &a = c.artifacts.items[i];
    const auto prior_reserved = c.reserved; c.reserved += total;
    c.peak = c.peak > c.used + c.reserved ? c.peak : c.used + c.reserved;
    try {
        if (output_size) { a.triangles = static_cast<ArtifactTriangle *>(allocate_payload(c, output_size)); a.output_bytes = output_q; }
        if (r.scratch_capacity_bytes) { a.scratch = allocate_payload(c, r.scratch_capacity_bytes); a.scratch_bytes = scratch_q; }
    } catch (const std::bad_alloc &) {
        c.used -= a.output_bytes + a.scratch_bytes;
        free_raw(a.triangles, c.config.allocation_alignment); free_raw(a.scratch, c.config.allocation_alignment);
        recycle(c.artifacts, i); c.reserved = prior_reserved;
        return failed<ArtifactBuilder>(ArtifactReason::allocation_failed);
    }
    a.stamp = stamp; a.capacity = r.triangle_capacity; a.owner_session = si;
    a.owner_session_cookie = session.base.cookie; a.owner_epoch = 1; a.builder_session_edge = true;
    ++session.base.refs;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<ArtifactBuilderTag>(c, i)};
}
ArtifactReason NativeCollisionArtifactDomain::append(ArtifactBuilder &b, const ArtifactTriangle &t) {
    auto why = Access::check(control_, b); if (why != ArtifactReason::none) return why;
    auto &a = control_->artifacts.items[Access::index(b)];
    why = artifact_current(*control_, a); if (why != ArtifactReason::none) return why;
    if (a.sealed) return ArtifactReason::stale_token;
    if (!triangle_finite(t)) return ArtifactReason::nonfinite_vertex;
    if (a.count == a.capacity) return ArtifactReason::capacity;
    // No area/winding filters: finite degenerate and sliver triangles survive.
    new (a.triangles + a.count) ArtifactTriangle(t); ++a.count;
    return ArtifactReason::none;
}
ArtifactResult<CollisionArtifact> NativeCollisionArtifactDomain::seal(ArtifactBuilder &b) {
    auto why = Access::check(control_, b); if (why != ArtifactReason::none) return failed<CollisionArtifact>(why);
    auto &c = *control_; auto &a = c.artifacts.items[Access::index(b)];
    why = artifact_current(c, a); if (why != ArtifactReason::none) return failed<CollisionArtifact>(why);
    if (a.sealed) return failed<CollisionArtifact>(ArtifactReason::stale_token);
    a.sealed = true; a.builder_session_edge = false;
    release_slot(c, Kind::session, a.owner_session);
    c.used -= a.scratch_bytes; free_raw(a.scratch, c.config.allocation_alignment); a.scratch = nullptr; a.scratch_bytes = 0;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::convert<CollisionArtifactTag>(b)};
}
ArtifactReason NativeCollisionArtifactDomain::cancel(ArtifactBuilder &b) {
    const auto why = Access::check(control_, b); if (why != ArtifactReason::none) return why;
    control_->artifacts.items[Access::index(b)].cancelled = true;
    return ArtifactReason::none;
}
ArtifactReason NativeCollisionArtifactDomain::release_builder(ArtifactBuilder &b) {
    const auto why = cancel(b); if (why != ArtifactReason::none) return why;
    Access::reset(b); return ArtifactReason::none;
}
ArtifactResult<CollisionArtifact> NativeCollisionArtifactDomain::clone_artifact(const CollisionArtifact &a) {
    auto why = Access::check(control_, a);
    if (why == ArtifactReason::none) why = artifact_current(*control_, control_->artifacts.items[Access::index(a)]);
    return clone(control_, a, why);
}
ArtifactResult<ArtifactRole> NativeCollisionArtifactDomain::acquire_role(const CollisionArtifact &artifact, const ArtifactSession &session) {
    auto why = Access::check(control_, artifact); if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    why = Access::check(control_, session); if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    auto &c = *control_; const auto ai = Access::index(artifact), si = Access::index(session);
    auto &a = c.artifacts.items[ai]; auto &s = c.sessions.items[si];
    why = artifact_current(c, a); if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    if (!a.sealed) return failed<ArtifactRole>(ArtifactReason::incomplete);
    if (a.owner_session != si || a.owner_session_cookie != s.base.cookie) return failed<ArtifactRole>(ArtifactReason::wrong_owner);
    if (c.roles.free == absent || c.free_credit == absent) return failed<ArtifactRole>(ArtifactReason::capacity);
    if (!room(c, a.base) || !room(c, s.base)) return failed<ArtifactRole>(ArtifactReason::reference_exhausted);
    std::uint64_t cookie; why = next_cookie(c, cookie); if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    const auto ri = open(c.roles, cookie); auto &r = c.roles.items[ri];
    r.artifact = ai; r.session = si; r.artifact_cookie = a.base.cookie; r.session_cookie = s.base.cookie; r.epoch = a.owner_epoch;
    ++a.base.refs; ++s.base.refs;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<ArtifactRoleTag>(c, ri)};
}
ArtifactResult<ArtifactRole> NativeCollisionArtifactDomain::clone_role(const ArtifactRole &r) {
    auto why = Access::check(control_, r);
    if (why == ArtifactReason::none) why = role_current(*control_, control_->roles.items[Access::index(r)]);
    return clone(control_, r, why);
}
ArtifactResult<ArtifactTransfer> NativeCollisionArtifactDomain::begin_transfer(const ArtifactRole &origin, const ArtifactSession &destination) {
    auto why = Access::check(control_, origin); if (why != ArtifactReason::none) return failed<ArtifactTransfer>(why);
    why = Access::check(control_, destination); if (why != ArtifactReason::none) return failed<ArtifactTransfer>(why);
    auto &c = *control_; const auto oi = Access::index(origin), di = Access::index(destination);
    auto &r = c.roles.items[oi]; auto &a = c.artifacts.items[r.artifact]; auto &d = c.sessions.items[di];
    why = role_current(c, r); if (why != ArtifactReason::none) return failed<ArtifactTransfer>(why);
    why = session_current(c, di, d.base.cookie); if (why != ArtifactReason::none) return failed<ArtifactTransfer>(why);
    const auto from = c.sessions.items[r.session].kind, to = d.kind;
    if (!((from == ArtifactOwnerKind::producer && (to == ArtifactOwnerKind::broker || to == ArtifactOwnerKind::receiver))
        || (from == ArtifactOwnerKind::broker && to == ArtifactOwnerKind::receiver))) return failed<ArtifactTransfer>(ArtifactReason::wrong_owner);
    if (a.pending_cookie) return failed<ArtifactTransfer>(ArtifactReason::competing_transfer);
    if (c.transfers.free == absent || c.roles.free == absent || c.free_credit == absent) return failed<ArtifactTransfer>(ArtifactReason::capacity);
    if (!room(c, r.base) || !room(c, a.base) || !room(c, d.base, 2)) return failed<ArtifactTransfer>(ArtifactReason::reference_exhausted);
    // Reserve both cookies before any occupied slot or owning edge changes.
    if (c.next_cookie >= std::numeric_limits<std::uint64_t>::max() - 1) {
        c.next_cookie = std::numeric_limits<std::uint64_t>::max();
        return failed<ArtifactTransfer>(ArtifactReason::cookie_exhausted);
    }
    std::uint64_t rc, tc; next_cookie(c, rc); next_cookie(c, tc);
    const auto ri = open(c.roles, rc), ti = open(c.transfers, tc);
    auto &reserved = c.roles.items[ri];
    reserved.artifact = r.artifact; reserved.session = di; reserved.artifact_cookie = a.base.cookie;
    reserved.session_cookie = d.base.cookie; reserved.epoch = a.owner_epoch; reserved.base.refs = 1;
    ++a.base.refs; ++d.base.refs;
    auto &t = c.transfers.items[ti]; t.origin_role = oi; t.destination_role = ri; t.destination_session = di;
    t.artifact = r.artifact; t.artifact_cookie = a.base.cookie; t.origin_epoch = a.owner_epoch;
    ++r.base.refs; ++d.base.refs;
    a.pending_cookie = tc; a.pending_epoch = a.owner_epoch;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<ArtifactTransferTag>(c, ti)};
}
ArtifactResult<ArtifactRole> NativeCollisionArtifactDomain::commit_transfer(ArtifactTransfer &transfer) {
    auto why = Access::check(control_, transfer); if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    auto &c = *control_; auto &t = c.transfers.items[Access::index(transfer)];
    if (t.state != TransferState::staged) return failed<ArtifactRole>(ArtifactReason::consumed_transfer);
    auto &a = c.artifacts.items[t.artifact]; auto &origin = c.roles.items[t.origin_role];
    why = role_current(c, origin); if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    why = session_current(c, t.destination_session, c.roles.items[t.destination_role].session_cookie);
    if (why != ArtifactReason::none) return failed<ArtifactRole>(why);
    if (t.invalidated || a.pending_cookie != t.base.cookie || a.pending_epoch != t.origin_epoch
        || a.owner_epoch != t.origin_epoch || a.base.cookie != t.artifact_cookie) return failed<ArtifactRole>(ArtifactReason::stale_token);
    if (a.owner_epoch == std::numeric_limits<std::uint64_t>::max()) return failed<ArtifactRole>(ArtifactReason::cookie_exhausted);
    if (c.free_credit == absent) return failed<ArtifactRole>(ArtifactReason::capacity);
    auto &r = c.roles.items[t.destination_role];
    if (!room(c, r.base)) return failed<ArtifactRole>(ArtifactReason::reference_exhausted);
    clear_pending(c, t); ++a.owner_epoch; a.owner_session = r.session; a.owner_session_cookie = r.session_cookie;
    r.epoch = a.owner_epoch; t.state = TransferState::committed;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<ArtifactRoleTag>(c, t.destination_role)};
}
ArtifactReason NativeCollisionArtifactDomain::abort_transfer(ArtifactTransfer &transfer) {
    const auto why = Access::check(control_, transfer); if (why != ArtifactReason::none) return why;
    auto &c = *control_; auto &t = c.transfers.items[Access::index(transfer)];
    if (t.state != TransferState::staged) return ArtifactReason::consumed_transfer;
    clear_pending(c, t); t.state = TransferState::aborted;
    return ArtifactReason::none;
}
ArtifactResult<ArtifactHold> NativeCollisionArtifactDomain::retain_backing(const CollisionArtifact &artifact) {
    auto why = Access::check(control_, artifact); if (why != ArtifactReason::none) return failed<ArtifactHold>(why);
    auto &c = *control_; const auto ai = Access::index(artifact); auto &a = c.artifacts.items[ai];
    why = artifact_current(c, a); if (why != ArtifactReason::none) return failed<ArtifactHold>(why);
    if (c.holds.free == absent || c.free_credit == absent) return failed<ArtifactHold>(ArtifactReason::capacity);
    if (!room(c, a.base)) return failed<ArtifactHold>(ArtifactReason::reference_exhausted);
    std::uint64_t cookie; why = next_cookie(c, cookie); if (why != ArtifactReason::none) return failed<ArtifactHold>(why);
    const auto hi = open(c.holds, cookie); auto &h = c.holds.items[hi]; h.artifact = ai; h.artifact_cookie = a.base.cookie; ++a.base.refs;
    return {ArtifactStatus::ready, ArtifactReason::none, Access::issue<ArtifactHoldTag>(c, hi)};
}
ArtifactResult<ArtifactHold> NativeCollisionArtifactDomain::clone_hold(const ArtifactHold &h) {
    auto why = Access::check(control_, h);
    if (why == ArtifactReason::none) why = artifact_current(*control_, control_->artifacts.items[control_->holds.items[Access::index(h)].artifact]);
    return clone(control_, h, why);
}
ArtifactReason NativeCollisionArtifactDomain::cancel(const CollisionArtifact &artifact) {
    const auto why = Access::check(control_, artifact); if (why != ArtifactReason::none) return why;
    control_->artifacts.items[Access::index(artifact)].cancelled = true;
    return ArtifactReason::none;
}
ArtifactReason NativeCollisionArtifactDomain::release_role(ArtifactRole &role) {
    const auto why = Access::check(control_, role); if (why != ArtifactReason::none) return why;
    auto &c = *control_; auto &r = c.roles.items[Access::index(role)];
    r.released = true;
    // The transfer's counted origin edge retains this record. Its released
    // flag rejects commit even if other aliases/current-owner roles survive.
    // The artifact guard remains until exact abort/final transfer destruction.
    Access::reset(role); return ArtifactReason::none;
}
ArtifactReason NativeCollisionArtifactDomain::release_hold(ArtifactHold &hold) {
    const auto why = Access::check(control_, hold); if (why != ArtifactReason::none) return why;
    Access::reset(hold); return ArtifactReason::none;
}
ArtifactResult<ArtifactMetadata> NativeCollisionArtifactDomain::snapshot(const CollisionArtifact &artifact) const {
    const auto why = Access::check(control_, artifact); if (why != ArtifactReason::none) return failed<ArtifactMetadata>(why);
    const auto &a = control_->artifacts.items[Access::index(artifact)];
    // Observational metadata remains available after revocation; it does not
    // authorize geometry access, transfer, currentness, or any publication.
    return {ArtifactStatus::ready, ArtifactReason::none, {a.base.cookie, a.base.cookie, a.owner_epoch,
        a.stamp, a.count, a.capacity, a.output_bytes + a.scratch_bytes, a.sealed,
        a.cancelled || artifact_current(*control_, a) != ArtifactReason::none}};
}
ArtifactResult<ArtifactAccounting> NativeCollisionArtifactDomain::accounting() const {
    if (!owner(control_)) return failed<ArtifactAccounting>(control_ ? ArtifactReason::wrong_thread : ArtifactReason::closed);
    return {ArtifactStatus::ready, ArtifactReason::none, artifact_detail::accounting(*control_)};
}
ArtifactReason NativeCollisionArtifactDomain::close() {
    if (!owner(control_)) return control_ ? ArtifactReason::wrong_thread : ArtifactReason::closed;
    control_->closed = true; return ArtifactReason::none;
}
ArtifactDrainResult NativeCollisionArtifactDomain::drain(std::size_t maximum_slots) {
    if (!owner(control_)) return {ArtifactStatus::rejected, control_ ? ArtifactReason::wrong_thread : ArtifactReason::closed, 0, false};
    if (!maximum_slots) return {ArtifactStatus::rejected, ArtifactReason::invalid_configuration, 0, false};
    auto &c = *control_;
    const auto slots = c.config.session_slots + c.config.artifact_slots + c.config.role_slots
        + c.config.transfer_slots + c.config.hold_slots;
    const auto visits = maximum_slots < slots ? maximum_slots : slots;
    // Each visit validates exactly one fixed slot, then persists its cursor.
    // Ownership cleanup follows final-reference edges, never an all-slot scan.
    for (std::size_t n = 0; n != visits; ++n) {
        auto index = c.cursor;
        Base *visited;
        if (index < c.sessions.capacity) visited = &c.sessions.items[index].base;
        else if ((index -= c.sessions.capacity) < c.artifacts.capacity) visited = &c.artifacts.items[index].base;
        else if ((index -= c.artifacts.capacity) < c.roles.capacity) visited = &c.roles.items[index].base;
        else if ((index -= c.roles.capacity) < c.transfers.capacity) visited = &c.transfers.items[index].base;
        else { index -= c.transfers.capacity; visited = &c.holds.items[index].base; }
        if (visited->occupied && !visited->refs) std::terminate();
        c.cursor = c.cursor + 1 == slots ? 0 : c.cursor + 1;
    }
    const bool empty = c.artifacts.occupied == 0;
    return {empty ? ArtifactStatus::ready : ArtifactStatus::pending,
        empty ? ArtifactReason::none : ArtifactReason::outstanding_holders, visits, empty};
}
ArtifactAllocationTotals NativeCollisionArtifactDomain::allocation_totals() noexcept {
    return {global_bytes.load(std::memory_order_relaxed), global_blocks.load(std::memory_order_relaxed),
        global_allocations.load(std::memory_order_relaxed), global_deallocations.load(std::memory_order_relaxed)};
}
std::size_t NativeCollisionArtifactDomain::checked_requested_bytes(std::size_t bytes, std::size_t a) { return requested(bytes, a); }
void NativeCollisionArtifactDomain::test_force_cookie_exhaustion() {
    if (!owner(control_)) throw std::logic_error("artifact test owner thread");
    control_->next_cookie = std::numeric_limits<std::uint64_t>::max();
}
}
