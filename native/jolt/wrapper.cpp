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
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr JPH::ObjectLayer layer_static = 0;
constexpr JPH::ObjectLayer layer_moving = 1;
constexpr JPH::ObjectLayer layer_cosmetic = 2;
constexpr JPH::BroadPhaseLayer broad_static(0);
constexpr JPH::BroadPhaseLayer broad_moving(1);
constexpr JPH::BroadPhaseLayer broad_cosmetic(2);
constexpr JPH::uint broad_layer_count = 3;

thread_local std::string last_error;
bool initialized = false;

void set_error(const std::string &message) {
    last_error = message;
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

class BroadPhaseLayers final : public JPH::BroadPhaseLayerInterface {
public:
    JPH::uint GetNumBroadPhaseLayers() const override {
        return broad_layer_count;
    }

    JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer layer) const override {
        switch (layer) {
        case layer_static:
            return broad_static;
        case layer_moving:
            return broad_moving;
        default:
            return broad_cosmetic;
        }
    }
};

class ObjectBroadPhaseFilter final : public JPH::ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer layer, JPH::BroadPhaseLayer broad_layer) const override {
        switch (layer) {
        case layer_static:
            return broad_layer == broad_moving || broad_layer == broad_cosmetic;
        case layer_moving:
            return broad_layer == broad_static || broad_layer == broad_moving;
        default:
            return broad_layer == broad_static || broad_layer == broad_cosmetic;
        }
    }
};

class ObjectPairFilter final : public JPH::ObjectLayerPairFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer first, JPH::ObjectLayer second) const override {
        if (first == layer_static) {
            return second != layer_static;
        }
        if (first == layer_moving) {
            return second == layer_static || second == layer_moving;
        }
        return second == layer_static || second == layer_cosmetic;
    }
};

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
    RFWorld()
        : temp_allocator(16 * 1024 * 1024),
          jobs(JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers,
               static_cast<int>(std::max(1u, std::thread::hardware_concurrency()) - 1)) {
        system.Init(4096, 0, 4096, 4096, broad_layers, object_broad_filter, object_pair_filter);
        system.SetGravity(JPH::Vec3(0.0f, -9.81f, 0.0f));
    }

    JPH::PhysicsSystem system;
    JPH::TempAllocatorImpl temp_allocator;
    JPH::JobSystemThreadPool jobs;
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

int rf_initialize(void) {
    if (initialized) {
        return 1;
    }
    JPH::RegisterDefaultAllocator();
    JPH::Factory::sInstance = new JPH::Factory();
    JPH::RegisterTypes();
    initialized = true;
    return 1;
}

void rf_shutdown(void) {
    if (!initialized) {
        return;
    }
    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
    initialized = false;
}

const char *rf_last_error(void) {
    return last_error.c_str();
}

RFWorld *rf_world_create(void) {
    if (!initialized) {
        set_error("Jolt is not initialized");
        return nullptr;
    }
    return new RFWorld();
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
}

void rf_world_step(RFWorld *world, float delta_time) {
    if (world == nullptr || delta_time <= 0.0f) {
        return;
    }
    world->system.Update(delta_time, 1, &world->temp_allocator, &world->jobs);
}

int rf_world_ray_cast(RFWorld *world, RFVec3 origin, RFVec3 direction, float distance, RFRayHit *out_hit) {
    if (world == nullptr || out_hit == nullptr || distance <= 0.0f) {
        return 0;
    }
    JPH::Vec3 normalized = vec(direction).NormalizedOr(JPH::Vec3::sZero());
    if (normalized.IsNearZero()) {
        return 0;
    }
    JPH::RRayCast ray(rvec(origin), normalized * distance);
    JPH::RayCastResult result;
    const bool hit = world->system.GetNarrowPhaseQuery().CastRay(
        ray,
        result,
        world->system.GetDefaultBroadPhaseLayerFilter(layer_moving),
        world->system.GetDefaultLayerFilter(layer_moving));
    if (!hit) {
        return 0;
    }
    out_hit->position = vec(ray.GetPointOnRay(result.mFraction));
    out_hit->fraction = result.mFraction;
    out_hit->body_id = result.mBodyID.GetIndexAndSequenceNumber();
    return 1;
}

static RFBody *create_body(RFWorld *world, const JPH::Shape *shape, RFTransform transform, int dynamic) {
    if (world == nullptr || shape == nullptr) {
        set_error("Invalid body parameters");
        return nullptr;
    }
    const JPH::EMotionType motion = dynamic ? JPH::EMotionType::Dynamic : JPH::EMotionType::Static;
    const JPH::ObjectLayer layer = dynamic ? layer_moving : layer_static;
    JPH::BodyCreationSettings settings(shape, rvec(transform.position), quat(transform.rotation), motion, layer);
    settings.mFriction = 0.7f;
    JPH::BodyInterface &interface = world->system.GetBodyInterface();
    JPH::BodyID id = interface.CreateAndAddBody(settings, dynamic ? JPH::EActivation::Activate : JPH::EActivation::DontActivate);
    if (id.IsInvalid()) {
        set_error("Jolt could not create a body");
        return nullptr;
    }
    RFBody *body = new RFBody{world, id};
    world->bodies.push_back(body);
    return body;
}

RFBody *rf_body_create_box(RFWorld *world, RFVec3 half_extents, RFTransform transform, int dynamic) {
    if (half_extents.x <= 0.0f || half_extents.y <= 0.0f || half_extents.z <= 0.0f) {
        set_error("Box extents must be positive");
        return nullptr;
    }
    JPH::RefConst<JPH::Shape> shape = new JPH::BoxShape(vec(half_extents));
    return create_body(world, shape.GetPtr(), transform, dynamic);
}

RFBody *rf_body_create_sphere(RFWorld *world, float radius, RFTransform transform, int dynamic) {
    if (radius <= 0.0f) {
        set_error("Sphere radius must be positive");
        return nullptr;
    }
    JPH::RefConst<JPH::Shape> shape = new JPH::SphereShape(radius);
    return create_body(world, shape.GetPtr(), transform, dynamic);
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

RFCharacter *rf_character_create(RFWorld *world, RFVec3 position, float half_height, float radius, float max_slope_radians) {
    if (world == nullptr || half_height <= 0.0f || radius <= 0.0f) {
        set_error("Invalid character parameters");
        return nullptr;
    }
    JPH::RefConst<JPH::Shape> shape = new JPH::CapsuleShape(half_height, radius);
    JPH::Ref<JPH::CharacterVirtualSettings> settings = new JPH::CharacterVirtualSettings();
    settings->mShape = shape;
    settings->mMaxSlopeAngle = max_slope_radians;
    settings->mSupportingVolume = JPH::Plane(JPH::Vec3::sAxisY(), -radius);
    settings->mEnhancedInternalEdgeRemoval = true;
    settings->mInnerBodyLayer = layer_moving;
    JPH::CharacterVirtual *character = new JPH::CharacterVirtual(
        settings, rvec(position), JPH::Quat::sIdentity(), 0, &world->system);
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
        world->system.GetDefaultBroadPhaseLayerFilter(layer_moving),
        world->system.GetDefaultLayerFilter(layer_moving),
        {},
        {},
        world->temp_allocator);
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

RFRagdoll *rf_ragdoll_create(RFWorld *world, const RFRagdollPart *parts, size_t count, RFVec3 linear_velocity, RFVec3 root_impulse) {
    if (world == nullptr || parts == nullptr || count == 0) {
        set_error("Invalid ragdoll parameters");
        return nullptr;
    }
    RFRagdoll *ragdoll = new RFRagdoll{world, {}, {}};
    ragdoll->bodies.reserve(count);
    std::vector<JPH::Body *> created;
    created.reserve(count);
    JPH::Ref<JPH::GroupFilterTable> filter = new JPH::GroupFilterTable(static_cast<JPH::uint>(count));
    for (size_t i = 0; i < count; ++i) {
        if (parts[i].parent >= static_cast<int32_t>(i) || parts[i].parent < -1) {
            set_error("Ragdoll parents must precede their children");
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
            set_error("Unknown ragdoll shape");
            rf_ragdoll_destroy(ragdoll);
            return nullptr;
        }
        JPH::BodyCreationSettings settings(
            shape.GetPtr(), rvec(part.transform.position), quat(part.transform.rotation),
            JPH::EMotionType::Dynamic, layer_cosmetic);
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
            set_error("Jolt could not create a ragdoll body");
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
            set_error("Unknown ragdoll joint");
            rf_ragdoll_destroy(ragdoll);
            return nullptr;
        }
        if (constraint == nullptr) {
            set_error("Jolt could not create a ragdoll constraint");
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
