#ifndef RAVENFIELD_JOLT_WRAPPER_H
#define RAVENFIELD_JOLT_WRAPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RFWorld RFWorld;
typedef struct RFBody RFBody;
typedef struct RFCharacter RFCharacter;
typedef struct RFRagdoll RFRagdoll;

typedef struct RFVec3 {
    float x;
    float y;
    float z;
} RFVec3;

typedef struct RFQuat {
    float x;
    float y;
    float z;
    float w;
} RFQuat;

typedef struct RFTransform {
    RFVec3 position;
    RFQuat rotation;
} RFTransform;

typedef struct RFRayHit {
    RFVec3 position;
    float fraction;
    uint32_t body_id;
} RFRayHit;

typedef enum RFShapeKind {
    RF_SHAPE_BOX = 0,
    RF_SHAPE_CAPSULE = 1,
    RF_SHAPE_SPHERE = 2
} RFShapeKind;

typedef enum RFJointKind {
    RF_JOINT_NONE = 0,
    RF_JOINT_POINT = 1,
    RF_JOINT_HINGE = 2,
    RF_JOINT_SWING_TWIST = 3
} RFJointKind;

typedef struct RFRagdollPart {
    RFTransform transform;
    RFVec3 size;
    float mass;
    int32_t parent;
    int32_t shape;
    int32_t joint;
    RFVec3 joint_pivot;
    RFVec3 joint_axis;
    float joint_limit;
} RFRagdollPart;

int rf_initialize(void);
void rf_shutdown(void);
const char *rf_last_error(void);

RFWorld *rf_world_create(void);
void rf_world_destroy(RFWorld *world);
void rf_world_step(RFWorld *world, float delta_time);
int rf_world_ray_cast(RFWorld *world, RFVec3 origin, RFVec3 direction, float distance, RFRayHit *out_hit);

RFBody *rf_body_create_box(RFWorld *world, RFVec3 half_extents, RFTransform transform, int dynamic);
RFBody *rf_body_create_sphere(RFWorld *world, float radius, RFTransform transform, int dynamic);
void rf_body_destroy(RFBody *body);
RFTransform rf_body_get_transform(const RFBody *body);
void rf_body_set_transform(RFBody *body, RFTransform transform);
void rf_body_set_linear_velocity(RFBody *body, RFVec3 velocity);
RFVec3 rf_body_get_linear_velocity(const RFBody *body);
void rf_body_add_impulse(RFBody *body, RFVec3 impulse);
int rf_body_is_active(const RFBody *body);

RFCharacter *rf_character_create(RFWorld *world, RFVec3 position, float half_height, float radius, float max_slope_radians);
void rf_character_destroy(RFCharacter *character);
void rf_character_update(RFCharacter *character, float delta_time);
RFVec3 rf_character_get_position(const RFCharacter *character);
void rf_character_set_position(RFCharacter *character, RFVec3 position);
RFVec3 rf_character_get_linear_velocity(const RFCharacter *character);
void rf_character_set_linear_velocity(RFCharacter *character, RFVec3 velocity);
int rf_character_is_grounded(const RFCharacter *character);

RFRagdoll *rf_ragdoll_create(RFWorld *world, const RFRagdollPart *parts, size_t count, RFVec3 linear_velocity, RFVec3 root_impulse);
void rf_ragdoll_destroy(RFRagdoll *ragdoll);
void rf_ragdoll_get_transforms(const RFRagdoll *ragdoll, RFTransform *out_transforms, size_t count);
int rf_ragdoll_is_active(const RFRagdoll *ragdoll);
void rf_ragdoll_add_impulse(RFRagdoll *ragdoll, RFVec3 impulse);

#ifdef __cplusplus
}
#endif

#endif
