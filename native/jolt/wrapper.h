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

/* Functions that can fail write the reason here. The caller owns the buffer, so
   the message cannot be lost when the calling goroutine changes OS threads. */
typedef struct RFError {
    char message[256];
} RFError;

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

typedef enum RFLayer {
    RF_LAYER_STATIC = 0,
    RF_LAYER_CHARACTER = 1,
    RF_LAYER_VEHICLE = 2,
    RF_LAYER_DYNAMIC = 3,
    RF_LAYER_COSMETIC = 4,
    RF_LAYER_COUNT = 5
} RFLayer;

typedef enum RFBodyKind {
    RF_BODY_STATIC = 0,
    RF_BODY_DYNAMIC = 1,
    /* Dynamic, but on the cosmetic layer: only the world and ragdolls touch it. */
    RF_BODY_COSMETIC = 2
} RFBodyKind;

typedef struct RFRay {
    RFVec3 origin;
    RFVec3 direction;
    float distance;
} RFRay;

typedef struct RFRayHit {
    RFVec3 position;
    float fraction;
    uint32_t body_id;
    int32_t hit;
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

typedef struct RFCharacterDesc {
    RFVec3 position;
    float half_height;
    float radius;
    float max_slope_radians;
    float max_strength;
} RFCharacterDesc;

/* Initialization creates the job thread pool shared by all worlds. */
int rf_initialize(RFError *error);
/* Fails while any world is still open. */
int rf_shutdown(RFError *error);

RFWorld *rf_world_create(RFError *error);
void rf_world_destroy(RFWorld *world);
void rf_world_step(RFWorld *world, float delta_time);
/* Layer masks have bit (1 << RFLayer) set for every layer a ray may hit. */
int rf_world_ray_cast(RFWorld *world, RFRay ray, uint32_t layer_mask, RFRayHit *out_hit);
/* Casts large batches in parallel on the shared pool. The world must not be stepped meanwhile. */
void rf_world_ray_cast_batch(RFWorld *world, const RFRay *rays, size_t count, uint32_t layer_mask, RFRayHit *out_hits);

RFBody *rf_body_create_box(RFWorld *world, RFVec3 half_extents, RFTransform transform, int kind, RFError *error);
RFBody *rf_body_create_sphere(RFWorld *world, float radius, RFTransform transform, int kind, RFError *error);
void rf_body_destroy(RFBody *body);
/* Matches RFRayHit.body_id of hits on this body. */
uint32_t rf_body_get_id(const RFBody *body);
RFTransform rf_body_get_transform(const RFBody *body);
void rf_body_set_transform(RFBody *body, RFTransform transform);
void rf_body_set_linear_velocity(RFBody *body, RFVec3 velocity);
RFVec3 rf_body_get_linear_velocity(const RFBody *body);
void rf_body_add_impulse(RFBody *body, RFVec3 impulse);
int rf_body_is_active(const RFBody *body);

RFCharacter *rf_character_create(RFWorld *world, RFCharacterDesc desc, RFError *error);
void rf_character_destroy(RFCharacter *character);
void rf_character_update(RFCharacter *character, float delta_time);
/* Recomputes contacts and ground state after a teleport. It cannot rebuild what
   the previous update learned from collisions, so it does not replace a saved state. */
void rf_character_refresh_contacts(RFCharacter *character);
/* Saves position, velocity, ground state and the contacts the next update reads.
   Returns the state size; the state is written only when it fits into capacity. */
size_t rf_character_save_state(const RFCharacter *character, uint8_t *buffer, size_t capacity);
int rf_character_restore_state(RFCharacter *character, const uint8_t *state, size_t size);
RFVec3 rf_character_get_position(const RFCharacter *character);
void rf_character_set_position(RFCharacter *character, RFVec3 position);
RFVec3 rf_character_get_linear_velocity(const RFCharacter *character);
void rf_character_set_linear_velocity(RFCharacter *character, RFVec3 velocity);
int rf_character_is_grounded(const RFCharacter *character);

RFRagdoll *rf_ragdoll_create(RFWorld *world, const RFRagdollPart *parts, size_t count, RFVec3 linear_velocity, RFVec3 root_impulse, RFError *error);
void rf_ragdoll_destroy(RFRagdoll *ragdoll);
void rf_ragdoll_get_transforms(const RFRagdoll *ragdoll, RFTransform *out_transforms, size_t count);
int rf_ragdoll_is_active(const RFRagdoll *ragdoll);
void rf_ragdoll_add_impulse(RFRagdoll *ragdoll, RFVec3 impulse);

#ifdef __cplusplus
}
#endif

#endif
