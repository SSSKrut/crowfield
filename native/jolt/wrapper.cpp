#include "wrapper.h"

#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Character/CharacterVirtual.h>
#include <Jolt/Physics/Collision/BroadPhase/BroadPhaseLayer.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/CollisionGroup.h>
#include <Jolt/Physics/Collision/GroupFilterTable.h>
#include <Jolt/Physics/Collision/NarrowPhaseQuery.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Constraints/HingeConstraint.h>
#include <Jolt/Physics/Constraints/PointConstraint.h>
#include <Jolt/Physics/Constraints/SwingTwistConstraint.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/StateRecorderImpl.h>
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr JPH::BroadPhaseLayer broad_static(0);
constexpr JPH::BroadPhaseLayer broad_moving(1);
constexpr JPH::BroadPhaseLayer broad_cosmetic(2);
constexpr JPH::uint broad_layer_count = 3;

constexpr uint32_t bit(RFLayer layer) {
    return 1u << layer;
}

// Which layers each layer collides with. Characters do not collide with each
// other: remote soldiers are shown in the past, so a hard contact would break
// prediction. Cosmetic ragdolls only touch the world and each other.
constexpr uint32_t layer_collides[RF_LAYER_COUNT] = {
    /* static    */ bit(RF_LAYER_CHARACTER) | bit(RF_LAYER_VEHICLE) | bit(RF_LAYER_DYNAMIC) | bit(RF_LAYER_COSMETIC),
    /* character */ bit(RF_LAYER_STATIC) | bit(RF_LAYER_VEHICLE) | bit(RF_LAYER_DYNAMIC),
    /* vehicle   */ bit(RF_LAYER_STATIC) | bit(RF_LAYER_CHARACTER) | bit(RF_LAYER_VEHICLE) | bit(RF_LAYER_DYNAMIC),
    /* dynamic   */ bit(RF_LAYER_STATIC) | bit(RF_LAYER_CHARACTER) | bit(RF_LAYER_VEHICLE) | bit(RF_LAYER_DYNAMIC),
    /* cosmetic  */ bit(RF_LAYER_STATIC) | bit(RF_LAYER_COSMETIC),
};

constexpr bool layer_table_is_symmetric() {
    for (int first = 0; first < RF_LAYER_COUNT; ++first) {
        for (int second = 0; second < RF_LAYER_COUNT; ++second) {
            if (((layer_collides[first] >> second) & 1u) != ((layer_collides[second] >> first) & 1u)) {
                return false;
            }
        }
    }
    return true;
}
static_assert(layer_table_is_symmetric(), "layer collision table must be symmetric");

JPH::BroadPhaseLayer broad_layer(JPH::ObjectLayer layer) {
    switch (layer) {
    case RF_LAYER_STATIC:
        return broad_static;
    case RF_LAYER_COSMETIC:
        return broad_cosmetic;
    default:
        return broad_moving;
    }
}

bool initialized = false;
JPH::JobSystemThreadPool *jobs = nullptr;
std::atomic<int> open_worlds{0};

void set_error(RFError *error, const char *message) {
    if (error != nullptr) {
        std::snprintf(error->message, sizeof(error->message), "%s", message);
    }
}

JPH::Vec3 vec(RFVec3 value) {
    return {value.x, value.y, value.z};
}

JPH::RVec3 rvec(RFVec3 value) {
    return {value.x, value.y, value.z};
}

RFVec3 vec(JPH::Vec3Arg value) {
    return {static_cast<float>(value.GetX()), static_cast<float>(value.GetY()), static_cast<float>(value.GetZ())};
}

JPH::Quat quat(RFQuat value) {
    return JPH::Quat(value.x, value.y, value.z, value.w).Normalized();
}

RFQuat quat(JPH::QuatArg value) {
    return {value.GetX(), value.GetY(), value.GetZ(), value.GetW()};
}

RFTransform identity_transform() {
    return {{0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f, 1.0f}};
}

// Broad phase layers that contain at least one layer from the mask.
uint32_t broad_mask(uint32_t layer_mask) {
    uint32_t mask = 0;
    for (JPH::ObjectLayer layer = 0; layer < RF_LAYER_COUNT; ++layer) {
        if ((layer_mask >> layer) & 1u) {
            mask |= 1u << broad_layer(layer).GetValue();
        }
    }
    return mask;
}

class BroadPhaseLayers final : public JPH::BroadPhaseLayerInterface {
public:
    JPH::uint GetNumBroadPhaseLayers() const override {
        return broad_layer_count;
    }

    JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer layer) const override {
        return broad_layer(layer);
    }
};

class ObjectBroadPhaseFilter final : public JPH::ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer layer, JPH::BroadPhaseLayer broad) const override {
        return layer < RF_LAYER_COUNT && ((broad_mask(layer_collides[layer]) >> broad.GetValue()) & 1u) != 0;
    }
};

class ObjectPairFilter final : public JPH::ObjectLayerPairFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer first, JPH::ObjectLayer second) const override {
        return first < RF_LAYER_COUNT && second < RF_LAYER_COUNT && ((layer_collides[first] >> second) & 1u) != 0;
    }
};

class MaskBroadPhaseFilter final : public JPH::BroadPhaseLayerFilter {
public:
    explicit MaskBroadPhaseFilter(uint32_t layer_mask) : mask(broad_mask(layer_mask)) {}

    bool ShouldCollide(JPH::BroadPhaseLayer layer) const override {
        return ((mask >> layer.GetValue()) & 1u) != 0;
    }

private:
    uint32_t mask;
};

class MaskObjectLayerFilter final : public JPH::ObjectLayerFilter {
public:
    explicit MaskObjectLayerFilter(uint32_t layer_mask) : mask(layer_mask) {}

    bool ShouldCollide(JPH::ObjectLayer layer) const override {
        return layer < RF_LAYER_COUNT && ((mask >> layer) & 1u) != 0;
    }

private:
    uint32_t mask;
};

void cast_ray(
    const JPH::NarrowPhaseQuery &query, const RFRay &ray, const JPH::BroadPhaseLayerFilter &broad_filter,
    const JPH::ObjectLayerFilter &object_filter, RFRayHit &out_hit) {
    out_hit = {};
    const JPH::Vec3 direction = vec(ray.direction).NormalizedOr(JPH::Vec3::sZero());
    if (ray.distance <= 0.0f || direction.IsNearZero()) {
        return;
    }
    JPH::RRayCast cast(rvec(ray.origin), direction * ray.distance);
    JPH::RayCastResult result;
    if (!query.CastRay(cast, result, broad_filter, object_filter)) {
        return;
    }
    out_hit.position = vec(cast.GetPointOnRay(result.mFraction));
    out_hit.fraction = result.mFraction;
    out_hit.body_id = result.mBodyID.GetIndexAndSequenceNumber();
    out_hit.hit = 1;
}

constexpr size_t rays_per_job = 32;

JPH::Vec3 perpendicular(JPH::Vec3Arg axis) {
    JPH::Vec3 normalized = axis.NormalizedOr(JPH::Vec3::sAxisY());
    JPH::Vec3 reference = std::abs(normalized.Dot(JPH::Vec3::sAxisY())) > 0.9f
        ? JPH::Vec3::sAxisX()
        : JPH::Vec3::sAxisY();
    return normalized.Cross(reference).Normalized();
}

template <typename T>
void forget(std::vector<T *> &items, T *item) {
    items.erase(std::remove(items.begin(), items.end(), item), items.end());
}

} // namespace

struct RFWorld {
    RFWorld() : temp_allocator(16 * 1024 * 1024) {
        system.Init(4096, 0, 4096, 4096, broad_layers, object_broad_filter, object_pair_filter);
        system.SetGravity(JPH::Vec3(0.0f, -9.81f, 0.0f));
    }

    JPH::PhysicsSystem system;
    JPH::TempAllocatorImpl temp_allocator;
    BroadPhaseLayers broad_layers;
    ObjectBroadPhaseFilter object_broad_filter;
    ObjectPairFilter object_pair_filter;
    std::vector<RFBody *> bodies;
    std::vector<RFCharacter *> characters;
    std::vector<RFRagdoll *> ragdolls;
    JPH::CollisionGroup::GroupID next_group = 1;
};

struct RFBody {
    RFWorld *world;
    JPH::BodyID id;
};

struct RFCharacter {
    RFWorld *world;
    JPH::Ref<JPH::CharacterVirtual> value;
};

struct RFRagdoll {
    RFWorld *world;
    std::vector<JPH::BodyID> bodies;
    std::vector<JPH::Ref<JPH::Constraint>> constraints;
};

int rf_initialize(RFError *error) {
    if (initialized) {
        return 1;
    }
    JPH::RegisterDefaultAllocator();
    JPH::Factory::sInstance = new JPH::Factory();
    JPH::RegisterTypes();
    // Two worlds (the embedded server and the client) may step at the same
    // time, so the pool has room for two physics updates plus ray batches.
    const int threads = static_cast<int>(std::max(1u, std::thread::hardware_concurrency()) - 1);
    jobs = new JPH::JobSystemThreadPool(2 * JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers, threads);
    initialized = true;
    return 1;
}

int rf_shutdown(RFError *error) {
    if (!initialized) {
        return 1;
    }
    if (open_worlds.load() != 0) {
        char message[96];
        std::snprintf(message, sizeof(message), "%d physics worlds are still open", open_worlds.load());
        set_error(error, message);
        return 0;
    }
    delete jobs;
    jobs = nullptr;
    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
    initialized = false;
    return 1;
}

RFWorld *rf_world_create(RFError *error) {
    if (!initialized) {
        set_error(error, "Jolt is not initialized");
        return nullptr;
    }
    RFWorld *world = new RFWorld();
    ++open_worlds;
    return world;
}

void rf_world_destroy(RFWorld *world) {
    if (world == nullptr) {
        return;
    }
    while (!world->ragdolls.empty()) {
        rf_ragdoll_destroy(world->ragdolls.back());
    }
    while (!world->characters.empty()) {
        rf_character_destroy(world->characters.back());
    }
    while (!world->bodies.empty()) {
        rf_body_destroy(world->bodies.back());
    }
    delete world;
    --open_worlds;
}

void rf_world_step(RFWorld *world, float delta_time) {
    if (world == nullptr || delta_time <= 0.0f) {
        return;
    }
    world->system.Update(delta_time, 1, &world->temp_allocator, jobs);
}

int rf_world_ray_cast(RFWorld *world, RFRay ray, uint32_t layer_mask, RFRayHit *out_hit) {
    if (world == nullptr || out_hit == nullptr) {
        return 0;
    }
    cast_ray(world->system.GetNarrowPhaseQuery(), ray, MaskBroadPhaseFilter(layer_mask),
             MaskObjectLayerFilter(layer_mask), *out_hit);
    return out_hit->hit;
}

void rf_world_ray_cast_batch(RFWorld *world, const RFRay *rays, size_t count, uint32_t layer_mask, RFRayHit *out_hits) {
    if (world == nullptr || rays == nullptr || out_hits == nullptr || count == 0) {
        return;
    }
    const MaskBroadPhaseFilter broad_filter(layer_mask);
    const MaskObjectLayerFilter object_filter(layer_mask);
    const JPH::NarrowPhaseQuery &query = world->system.GetNarrowPhaseQuery();
    const auto cast_range = [&](size_t begin, size_t end) {
        for (size_t i = begin; i < end; ++i) {
            cast_ray(query, rays[i], broad_filter, object_filter, out_hits[i]);
        }
    };
    JPH::JobSystem::Barrier *barrier = count > rays_per_job ? jobs->CreateBarrier() : nullptr;
    if (barrier == nullptr) {
        cast_range(0, count);
        return;
    }
    for (size_t begin = 0; begin < count; begin += rays_per_job) {
        const size_t end = std::min(count, begin + rays_per_job);
        barrier->AddJob(jobs->CreateJob("RayCastBatch", JPH::Color::sGreen, [&cast_range, begin, end] {
            cast_range(begin, end);
        }));
    }
    jobs->WaitForJobs(barrier);
    jobs->DestroyBarrier(barrier);
}

static RFBody *create_body(RFWorld *world, const JPH::Shape *shape, RFTransform transform, int dynamic, RFError *error) {
    if (world == nullptr || shape == nullptr) {
        set_error(error, "Invalid body parameters");
        return nullptr;
    }
    const JPH::EMotionType motion = dynamic ? JPH::EMotionType::Dynamic : JPH::EMotionType::Static;
    const JPH::ObjectLayer layer = dynamic ? RF_LAYER_DYNAMIC : RF_LAYER_STATIC;
    JPH::BodyCreationSettings settings(shape, rvec(transform.position), quat(transform.rotation), motion, layer);
    settings.mFriction = 0.7f;
    JPH::BodyInterface &interface = world->system.GetBodyInterface();
    JPH::BodyID id = interface.CreateAndAddBody(settings, dynamic ? JPH::EActivation::Activate : JPH::EActivation::DontActivate);
    if (id.IsInvalid()) {
        set_error(error, "Jolt could not create a body");
        return nullptr;
    }
    RFBody *body = new RFBody{world, id};
    world->bodies.push_back(body);
    return body;
}

RFBody *rf_body_create_box(RFWorld *world, RFVec3 half_extents, RFTransform transform, int dynamic, RFError *error) {
    if (half_extents.x <= 0.0f || half_extents.y <= 0.0f || half_extents.z <= 0.0f) {
        set_error(error, "Box extents must be positive");
        return nullptr;
    }
    JPH::RefConst<JPH::Shape> shape = new JPH::BoxShape(vec(half_extents));
    return create_body(world, shape.GetPtr(), transform, dynamic, error);
}

RFBody *rf_body_create_sphere(RFWorld *world, float radius, RFTransform transform, int dynamic, RFError *error) {
    if (radius <= 0.0f) {
        set_error(error, "Sphere radius must be positive");
        return nullptr;
    }
    JPH::RefConst<JPH::Shape> shape = new JPH::SphereShape(radius);
    return create_body(world, shape.GetPtr(), transform, dynamic, error);
}

void rf_body_destroy(RFBody *body) {
    if (body == nullptr) {
        return;
    }
    JPH::BodyInterface &interface = body->world->system.GetBodyInterface();
    interface.RemoveBody(body->id);
    interface.DestroyBody(body->id);
    forget(body->world->bodies, body);
    delete body;
}

uint32_t rf_body_get_id(const RFBody *body) {
    return body == nullptr ? JPH::BodyID().GetIndexAndSequenceNumber() : body->id.GetIndexAndSequenceNumber();
}

RFTransform rf_body_get_transform(const RFBody *body) {
    if (body == nullptr) {
        return identity_transform();
    }
    const JPH::BodyInterface &interface = body->world->system.GetBodyInterface();
    return {vec(interface.GetPosition(body->id)), quat(interface.GetRotation(body->id))};
}

void rf_body_set_transform(RFBody *body, RFTransform transform) {
    if (body == nullptr) {
        return;
    }
    body->world->system.GetBodyInterface().SetPositionAndRotation(
        body->id, rvec(transform.position), quat(transform.rotation), JPH::EActivation::Activate);
}

void rf_body_set_linear_velocity(RFBody *body, RFVec3 velocity) {
    if (body != nullptr) {
        body->world->system.GetBodyInterface().SetLinearVelocity(body->id, vec(velocity));
    }
}

RFVec3 rf_body_get_linear_velocity(const RFBody *body) {
    if (body == nullptr) {
        return {0.0f, 0.0f, 0.0f};
    }
    return vec(body->world->system.GetBodyInterface().GetLinearVelocity(body->id));
}

void rf_body_add_impulse(RFBody *body, RFVec3 impulse) {
    if (body != nullptr) {
        body->world->system.GetBodyInterface().AddImpulse(body->id, vec(impulse));
    }
}

int rf_body_is_active(const RFBody *body) {
    return body != nullptr && body->world->system.GetBodyInterface().IsActive(body->id) ? 1 : 0;
}

RFCharacter *rf_character_create(RFWorld *world, RFCharacterDesc desc, RFError *error) {
    if (world == nullptr || desc.half_height <= 0.0f || desc.radius <= 0.0f || desc.max_strength < 0.0f) {
        set_error(error, "Invalid character parameters");
        return nullptr;
    }
    JPH::RefConst<JPH::Shape> shape = new JPH::CapsuleShape(desc.half_height, desc.radius);
    JPH::Ref<JPH::CharacterVirtualSettings> settings = new JPH::CharacterVirtualSettings();
    settings->mShape = shape;
    settings->mMaxSlopeAngle = desc.max_slope_radians;
    settings->mMaxStrength = desc.max_strength;
    settings->mSupportingVolume = JPH::Plane(JPH::Vec3::sAxisY(), -desc.radius);
    settings->mEnhancedInternalEdgeRemoval = true;
    settings->mInnerBodyLayer = RF_LAYER_CHARACTER;
    JPH::CharacterVirtual *character = new JPH::CharacterVirtual(
        settings, rvec(desc.position), JPH::Quat::sIdentity(), 0, &world->system);
    RFCharacter *result = new RFCharacter{world, character};
    world->characters.push_back(result);
    return result;
}

void rf_character_destroy(RFCharacter *character) {
    if (character == nullptr) {
        return;
    }
    forget(character->world->characters, character);
    delete character;
}

void rf_character_update(RFCharacter *character, float delta_time) {
    if (character == nullptr || delta_time <= 0.0f) {
        return;
    }
    RFWorld *world = character->world;
    character->value->UpdateGroundVelocity();
    JPH::CharacterVirtual::ExtendedUpdateSettings settings;
    character->value->ExtendedUpdate(
        delta_time,
        world->system.GetGravity(),
        settings,
        world->system.GetDefaultBroadPhaseLayerFilter(RF_LAYER_CHARACTER),
        world->system.GetDefaultLayerFilter(RF_LAYER_CHARACTER),
        {},
        {},
        world->temp_allocator);
}

void rf_character_refresh_contacts(RFCharacter *character) {
    if (character == nullptr) {
        return;
    }
    RFWorld *world = character->world;
    character->value->RefreshContacts(
        world->system.GetDefaultBroadPhaseLayerFilter(RF_LAYER_CHARACTER),
        world->system.GetDefaultLayerFilter(RF_LAYER_CHARACTER),
        {},
        {},
        world->temp_allocator);
}

size_t rf_character_save_state(const RFCharacter *character, uint8_t *buffer, size_t capacity) {
    if (character == nullptr) {
        return 0;
    }
    JPH::StateRecorderImpl recorder;
    character->value->SaveState(recorder);
    const std::string state = recorder.GetData();
    if (buffer != nullptr && state.size() <= capacity) {
        std::memcpy(buffer, state.data(), state.size());
    }
    return state.size();
}

int rf_character_restore_state(RFCharacter *character, const uint8_t *state, size_t size) {
    if (character == nullptr || state == nullptr || size == 0) {
        return 0;
    }
    JPH::StateRecorderImpl recorder;
    recorder.WriteBytes(state, size);
    character->value->RestoreState(recorder);
    return recorder.IsFailed() ? 0 : 1;
}

RFVec3 rf_character_get_position(const RFCharacter *character) {
    if (character == nullptr) {
        return {0.0f, 0.0f, 0.0f};
    }
    return vec(character->value->GetPosition());
}

void rf_character_set_position(RFCharacter *character, RFVec3 position) {
    if (character != nullptr) {
        character->value->SetPosition(rvec(position));
    }
}

RFVec3 rf_character_get_linear_velocity(const RFCharacter *character) {
    if (character == nullptr) {
        return {0.0f, 0.0f, 0.0f};
    }
    return vec(character->value->GetLinearVelocity());
}

void rf_character_set_linear_velocity(RFCharacter *character, RFVec3 velocity) {
    if (character != nullptr) {
        character->value->SetLinearVelocity(vec(velocity));
    }
}

int rf_character_is_grounded(const RFCharacter *character) {
    return character != nullptr && character->value->GetGroundState() == JPH::CharacterVirtual::EGroundState::OnGround ? 1 : 0;
}

RFRagdoll *rf_ragdoll_create(RFWorld *world, const RFRagdollPart *parts, size_t count, RFVec3 linear_velocity, RFVec3 root_impulse, RFError *error) {
    if (world == nullptr || parts == nullptr || count == 0) {
        set_error(error, "Invalid ragdoll parameters");
        return nullptr;
    }
    RFRagdoll *ragdoll = new RFRagdoll{world, {}, {}};
    ragdoll->bodies.reserve(count);
    std::vector<JPH::Body *> created;
    created.reserve(count);
    JPH::Ref<JPH::GroupFilterTable> filter = new JPH::GroupFilterTable(static_cast<JPH::uint>(count));
    for (size_t i = 0; i < count; ++i) {
        if (parts[i].parent >= static_cast<int32_t>(i) || parts[i].parent < -1) {
            set_error(error, "Ragdoll parents must precede their children");
            delete ragdoll;
            return nullptr;
        }
        for (size_t j = i + 1; j < count; ++j) {
            filter->DisableCollision(static_cast<JPH::uint>(i), static_cast<JPH::uint>(j));
        }
    }

    JPH::BodyInterface &interface = world->system.GetBodyInterface();
    for (size_t i = 0; i < count; ++i) {
        const RFRagdollPart &part = parts[i];
        JPH::RefConst<JPH::Shape> shape;
        switch (part.shape) {
        case RF_SHAPE_BOX:
            shape = new JPH::BoxShape(vec(part.size));
            break;
        case RF_SHAPE_CAPSULE:
            shape = new JPH::CapsuleShape(part.size.x, part.size.y);
            break;
        case RF_SHAPE_SPHERE:
            shape = new JPH::SphereShape(part.size.x);
            break;
        default:
            set_error(error, "Unknown ragdoll shape");
            rf_ragdoll_destroy(ragdoll);
            return nullptr;
        }
        JPH::BodyCreationSettings settings(
            shape.GetPtr(), rvec(part.transform.position), quat(part.transform.rotation),
            JPH::EMotionType::Dynamic, RF_LAYER_COSMETIC);
        settings.mCollisionGroup = JPH::CollisionGroup(
            filter, world->next_group, static_cast<JPH::CollisionGroup::SubGroupID>(i));
        settings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = std::max(0.1f, part.mass);
        settings.mFriction = 0.8f;
        settings.mLinearDamping = 0.08f;
        settings.mAngularDamping = 0.15f;
        settings.mLinearVelocity = vec(linear_velocity);
        JPH::Body *body = interface.CreateBody(settings);
        if (body == nullptr) {
            set_error(error, "Jolt could not create a ragdoll body");
            rf_ragdoll_destroy(ragdoll);
            return nullptr;
        }
        interface.AddBody(body->GetID(), JPH::EActivation::Activate);
        created.push_back(body);
        ragdoll->bodies.push_back(body->GetID());
    }
    ++world->next_group;

    for (size_t i = 0; i < count; ++i) {
        const RFRagdollPart &part = parts[i];
        if (part.parent < 0 || part.joint == RF_JOINT_NONE) {
            continue;
        }
        JPH::Body &parent = *created[part.parent];
        JPH::Body &child = *created[i];
        JPH::Constraint *constraint = nullptr;
        const JPH::Vec3 axis = vec(part.joint_axis).NormalizedOr(JPH::Vec3::sAxisY());
        const JPH::Vec3 normal = perpendicular(axis);
        if (part.joint == RF_JOINT_POINT) {
            JPH::PointConstraintSettings settings;
            settings.mSpace = JPH::EConstraintSpace::WorldSpace;
            settings.mPoint1 = rvec(part.joint_pivot);
            settings.mPoint2 = rvec(part.joint_pivot);
            constraint = settings.Create(parent, child);
        } else if (part.joint == RF_JOINT_HINGE) {
            JPH::HingeConstraintSettings settings;
            settings.mSpace = JPH::EConstraintSpace::WorldSpace;
            settings.mPoint1 = rvec(part.joint_pivot);
            settings.mPoint2 = rvec(part.joint_pivot);
            settings.mHingeAxis1 = axis;
            settings.mHingeAxis2 = axis;
            settings.mNormalAxis1 = normal;
            settings.mNormalAxis2 = normal;
            settings.mLimitsMin = -part.joint_limit;
            settings.mLimitsMax = part.joint_limit;
            constraint = settings.Create(parent, child);
        } else if (part.joint == RF_JOINT_SWING_TWIST) {
            JPH::SwingTwistConstraintSettings settings;
            settings.mSpace = JPH::EConstraintSpace::WorldSpace;
            settings.mPosition1 = rvec(part.joint_pivot);
            settings.mPosition2 = rvec(part.joint_pivot);
            settings.mTwistAxis1 = axis;
            settings.mTwistAxis2 = axis;
            settings.mPlaneAxis1 = normal;
            settings.mPlaneAxis2 = normal;
            settings.mNormalHalfConeAngle = part.joint_limit;
            settings.mPlaneHalfConeAngle = part.joint_limit;
            settings.mTwistMinAngle = -0.5f * part.joint_limit;
            settings.mTwistMaxAngle = 0.5f * part.joint_limit;
            constraint = settings.Create(parent, child);
        } else {
            set_error(error, "Unknown ragdoll joint");
            rf_ragdoll_destroy(ragdoll);
            return nullptr;
        }
        if (constraint == nullptr) {
            set_error(error, "Jolt could not create a ragdoll constraint");
            rf_ragdoll_destroy(ragdoll);
            return nullptr;
        }
        world->system.AddConstraint(constraint);
        ragdoll->constraints.emplace_back(constraint);
    }
    if (!ragdoll->bodies.empty()) {
        interface.AddImpulse(ragdoll->bodies.front(), vec(root_impulse));
    }
    world->ragdolls.push_back(ragdoll);
    return ragdoll;
}

void rf_ragdoll_destroy(RFRagdoll *ragdoll) {
    if (ragdoll == nullptr) {
        return;
    }
    RFWorld *world = ragdoll->world;
    for (const JPH::Ref<JPH::Constraint> &constraint : ragdoll->constraints) {
        world->system.RemoveConstraint(constraint.GetPtr());
    }
    ragdoll->constraints.clear();
    JPH::BodyInterface &interface = world->system.GetBodyInterface();
    for (JPH::BodyID id : ragdoll->bodies) {
        interface.RemoveBody(id);
        interface.DestroyBody(id);
    }
    ragdoll->bodies.clear();
    forget(world->ragdolls, ragdoll);
    delete ragdoll;
}

void rf_ragdoll_get_transforms(const RFRagdoll *ragdoll, RFTransform *out_transforms, size_t count) {
    if (ragdoll == nullptr || out_transforms == nullptr) {
        return;
    }
    const size_t limit = std::min(count, ragdoll->bodies.size());
    const JPH::BodyInterface &interface = ragdoll->world->system.GetBodyInterface();
    for (size_t i = 0; i < limit; ++i) {
        out_transforms[i].position = vec(interface.GetPosition(ragdoll->bodies[i]));
        out_transforms[i].rotation = quat(interface.GetRotation(ragdoll->bodies[i]));
    }
}

int rf_ragdoll_is_active(const RFRagdoll *ragdoll) {
    if (ragdoll == nullptr) {
        return 0;
    }
    const JPH::BodyInterface &interface = ragdoll->world->system.GetBodyInterface();
    for (JPH::BodyID id : ragdoll->bodies) {
        if (interface.IsActive(id)) {
            return 1;
        }
    }
    return 0;
}

void rf_ragdoll_add_impulse(RFRagdoll *ragdoll, RFVec3 impulse) {
    if (ragdoll != nullptr && !ragdoll->bodies.empty()) {
        ragdoll->world->system.GetBodyInterface().AddImpulse(ragdoll->bodies.front(), vec(impulse));
    }
}
