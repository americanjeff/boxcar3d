// Generic physics capability only. This shim is the scalar FFI boundary:
// it hides all Box3D struct layout from Odin by allocating
// def/hull structs on the C side and exposing only opaque pointers + scalar
// getters/setters + packed-u64 IDs. No C struct layout crosses the FFI.
//
// Compiled with the same toolchain as Box3D itself (gcc/clang native,
// emcc/clang for wasm) so struct layouts are always correct.

#include "box3d/box3d.h"
#include "box3d/math_functions.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

b3WorldDef *shim_new_world_def(void) {
    b3WorldDef *def = (b3WorldDef *)malloc(sizeof(b3WorldDef));
    *def = b3DefaultWorldDef();
    return def;
}

void shim_free_world_def(b3WorldDef *def) { free(def); }

void shim_world_set_gravity(b3WorldDef *def, float x, float y, float z) {
    def->gravity = (b3Vec3){x, y, z};
}

void shim_world_set_contact_hertz(b3WorldDef *def, float hertz) {
    def->contactHertz = hertz;
}

void shim_world_set_contact_damping_ratio(b3WorldDef *def, float ratio) {
    def->contactDampingRatio = ratio;
}

void shim_world_set_restitution_threshold(b3WorldDef *def, float threshold) {
    def->restitutionThreshold = threshold;
}

void shim_world_set_contact_speed(b3WorldDef *def, float speed) {
    def->contactSpeed = speed;
}

b3BodyDef *shim_new_body_def(void) {
    b3BodyDef *def = (b3BodyDef *)malloc(sizeof(b3BodyDef));
    *def = b3DefaultBodyDef();
    return def;
}

void shim_free_body_def(b3BodyDef *def) { free(def); }

void shim_body_set_type(b3BodyDef *def, int type) {
    def->type = (b3BodyType)type;
}

void shim_body_set_position(b3BodyDef *def, float x, float y, float z) {
    def->position = (b3Vec3){x, y, z};
}

void shim_body_set_rotation(b3BodyDef *def, float x, float y, float z, float w) {
    def->rotation = (b3Quat){{x, y, z}, w};
}

void shim_body_set_linear_velocity(b3BodyDef *def, float x, float y, float z) {
    def->linearVelocity = (b3Vec3){x, y, z};
}

void shim_body_set_angular_velocity(b3BodyDef *def, float x, float y, float z) {
    def->angularVelocity = (b3Vec3){x, y, z};
}

void shim_body_set_enable_sleep(b3BodyDef *def, int flag) {
    def->enableSleep = (bool)flag;
}

void shim_body_set_awake(b3BodyDef *def, int flag) {
    def->isAwake = (bool)flag;
}

void shim_body_set_allow_fast_rotation(b3BodyDef *def, int flag) {
    def->allowFastRotation = (bool)flag;
}

void shim_body_set_is_bullet(b3BodyDef *def, int flag) {
    def->isBullet = (bool)flag;
}

b3ShapeDef *shim_new_shape_def(void) {
    b3ShapeDef *def = (b3ShapeDef *)malloc(sizeof(b3ShapeDef));
    *def = b3DefaultShapeDef();
    return def;
}

void shim_free_shape_def(b3ShapeDef *def) { free(def); }

void shim_shape_set_density(b3ShapeDef *def, float density) {
    def->density = density;
}

void shim_shape_set_friction(b3ShapeDef *def, float friction) {
    def->baseMaterial.friction = friction;
}

void shim_shape_set_restitution(b3ShapeDef *def, float restitution) {
    def->baseMaterial.restitution = restitution;
}

void shim_shape_set_rolling_resistance(b3ShapeDef *def, float rr) {
    def->baseMaterial.rollingResistance = rr;
}

// Speculative contacts can create ghost contacts when a hull is near but not
// touching a triangle (heightfield/mesh) surface.
void shim_shape_set_enable_speculative(b3ShapeDef *def, bool enable) {
    def->enableSpeculativeContact = enable;
}

// Set the b3Filter on a ShapeDef and enable custom filtering.
// categoryBits = what category this shape belongs to.
// maskBits = what categories this shape collides with.
// groupIndex = non-zero for group-based filtering (0 = unused).
void shim_shape_set_filter(b3ShapeDef *def, uint64_t categoryBits,
                           uint64_t maskBits, int groupIndex) {
    def->filter.categoryBits = categoryBits;
    def->filter.maskBits = maskBits;
    def->filter.groupIndex = groupIndex;
    def->enableCustomFiltering = true;
}

b3BoxHull *shim_make_box_hull(float hx, float hy, float hz) {
    b3BoxHull *hull = (b3BoxHull *)malloc(sizeof(b3BoxHull));
    *hull = b3MakeBoxHull(hx, hy, hz);
    return hull;
}

void shim_free_box_hull(b3BoxHull *hull) { free(hull); }

b3HullData *shim_box_hull_get_base(b3BoxHull *hull) { return &hull->base; }

// ─── Generic convex hull (b3CreateHull) ──────────────────────────────
// Heap-allocated hull from a point cloud (x,y,z triplets). Box3D clones the
// hull data into its world database on shape creation, so the caller may free
// immediately after b3CreateHullShape. Returns NULL on degenerate input.
b3HullData *shim_create_hull(const float *points, int pointCount, int maxVertexCount) {
    if (points == NULL || pointCount < 4) return NULL;
    return b3CreateHull((const b3Vec3 *)points, pointCount, maxVertexCount);
}

void shim_destroy_hull(b3HullData *hull) {
    if (hull != NULL) b3DestroyHull(hull);
}

// b3Sphere / b3Capsule are tiny POD structs; the shim owns them so Odin
// never touches the layout. Box3D copies what it needs on shape creation;
// the caller frees the struct after. memset so a future upstream field
// addition stays zero-initialized.

b3Sphere *shim_make_sphere(float radius) {
    b3Sphere *s = (b3Sphere *)malloc(sizeof(b3Sphere));
    memset(s, 0, sizeof(b3Sphere));
    s->center = (b3Vec3){0.0f, 0.0f, 0.0f};
    s->radius = radius;
    return s;
}

void shim_free_sphere(b3Sphere *s) { free(s); }

// Capsule along the local +X axis (matches the renderer's AppendCapsule).
// `length` is the cylinder distance between the two hemisphere centers.
b3Capsule *shim_make_capsule(float length, float radius) {
    b3Capsule *c = (b3Capsule *)malloc(sizeof(b3Capsule));
    memset(c, 0, sizeof(b3Capsule));
    c->center1 = (b3Vec3){-0.5f * length, 0.0f, 0.0f};
    c->center2 = (b3Vec3){0.5f * length, 0.0f, 0.0f};
    c->radius = radius;
    return c;
}

void shim_free_capsule(b3Capsule *c) { free(c); }

// b3HeightFieldData is a Box3D-owned blob (created by b3CreateWave, freed
// by b3DestroyHeightField). It must outlive the shape that references it.

b3HeightFieldData *shim_create_wave_heightfield(int rowCount, int columnCount,
                                                float sx, float sy, float sz,
                                                float rowFreq, float colFreq) {
    b3Vec3 scale = {sx, sy, sz};
    return b3CreateWave(rowCount, columnCount, scale, rowFreq, colFreq, false);
}

void shim_destroy_heightfield(b3HeightFieldData *hf) {
    b3DestroyHeightField(hf);
}

// Custom heightfield from an explicit grid of heights (countX × countZ,
// row-major: index = z * countX + x). The heights are copied by
// b3CreateHeightField (compressed to uint16), so the caller may free its
// array immediately after. `minHeight`/`maxHeight` are the quantization
// range the heights are clamped to.
b3HeightFieldData *shim_create_heightfield(float *heights, int countX, int countZ,
                                           float sx, float sy, float sz,
                                           float minHeight, float maxHeight) {
    b3HeightFieldDef def;
    memset(&def, 0, sizeof(def));
    def.heights = heights;
    def.materialIndices = NULL;
    def.scale = (b3Vec3){sx, sy, sz};
    def.countX = countX;
    def.countZ = countZ;
    def.globalMinimumHeight = minHeight;
    def.globalMaximumHeight = maxHeight;
    def.clockwiseWinding = false;
    return b3CreateHeightField(&def);
}

// b3WorldId  = {u16 index1, u16 generation}                 → packed into low 32 bits
// b3BodyId   = {i32 index1, u16 world0, u16 generation}     → packed into 64 bits
// b3ShapeId  = same as b3BodyId
// b3JointId  = {i32 index1, u16 world0, u16 generation}     → same as b3BodyId

static uint64_t pack_world(b3WorldId id) {
    return ((uint64_t)id.index1 << 16) | (uint64_t)id.generation;
}

static b3WorldId unpack_world(uint64_t v) {
    b3WorldId id = {(uint16_t)(v >> 16), (uint16_t)v};
    return id;
}

static uint64_t pack_body(b3BodyId id) {
    return ((uint64_t)(uint32_t)id.index1 << 32) | ((uint64_t)id.world0 << 16) |
           (uint64_t)id.generation;
}

static b3BodyId unpack_body(uint64_t v) {
    b3BodyId id = {(int32_t)(v >> 32), (uint16_t)(v >> 16), (uint16_t)v};
    return id;
}

// b3ShapeId / b3JointId have the same layout as b3BodyId; pack/unpack them
// the same way, reinterpreting through b3BodyId.
static uint64_t pack_joint(b3JointId id) {
    b3BodyId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_body(b);
}

static b3JointId unpack_joint(uint64_t v) {
    b3BodyId b = unpack_body(v);
    b3JointId id = {b.index1, b.world0, b.generation};
    return id;
}

static uint64_t pack_shape(b3ShapeId id) {
    b3BodyId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_body(b);
}

static b3ShapeId unpack_shape(uint64_t v) {
    b3BodyId b = unpack_body(v);
    b3ShapeId id = {b.index1, b.world0, b.generation};
    return id;
}

uint64_t shim_create_world(b3WorldDef *def) {
    return pack_world(b3CreateWorld(def));
}

uint64_t shim_create_body(uint64_t world, b3BodyDef *def) {
    return pack_body(b3CreateBody(unpack_world(world), def));
}

// Destroy a body and every shape and joint attached to it (b3DestroyBody).
// Do not keep the body's shape/joint ids after this.
void shim_destroy_body(uint64_t body) { b3DestroyBody(unpack_body(body)); }

uint64_t shim_create_hull_shape(uint64_t body, b3ShapeDef *def, b3HullData *hull) {
    b3ShapeId id = b3CreateHullShape(unpack_body(body), def, hull);
    b3ShapeId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_shape(b);
}

// Attach a convex hull shape with a baked local transform (runtime compound
// body: one dynamic body + many transformed hull shapes = a single rigid
// body, no weld drift). The hull is cloned then transformed (scale first),
// so the caller may free it immediately. Identity rotation; block offsets
// are axis-aligned.
uint64_t shim_create_transformed_hull_shape(uint64_t body, b3ShapeDef *def, b3HullData *hull,
                                             float px, float py, float pz,
                                             float sx, float sy, float sz) {
    b3Transform t;
    t.p = (b3Vec3){px, py, pz};
    t.q = b3Quat_identity;
    b3Vec3 scale = {sx, sy, sz};
    b3ShapeId id = b3CreateTransformedHullShape(unpack_body(body), def, hull, t, scale);
    b3ShapeId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_shape(b);
}

uint64_t shim_create_sphere_shape(uint64_t body, b3ShapeDef *def, b3Sphere *sphere) {
    b3ShapeId id = b3CreateSphereShape(unpack_body(body), def, sphere);
    b3BodyId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_body(b);
}

uint64_t shim_create_capsule_shape(uint64_t body, b3ShapeDef *def, b3Capsule *capsule) {
    b3ShapeId id = b3CreateCapsuleShape(unpack_body(body), def, capsule);
    b3BodyId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_body(b);
}

uint64_t shim_create_heightfield_shape(uint64_t body, b3ShapeDef *def,
                                        b3HeightFieldData *hf) {
    b3ShapeId id = b3CreateHeightFieldShape(unpack_body(body), def, hf);
    b3BodyId b = {(int32_t)id.index1, id.world0, id.generation};
    return pack_body(b);
}

void shim_world_step(uint64_t world, float dt, int substeps) {
    b3World_Step(unpack_world(world), dt, substeps);
}

void shim_body_get_position(uint64_t body, float *x, float *y, float *z) {
    b3Vec3 p = b3Body_GetPosition(unpack_body(body));
    *x = p.x;
    *y = p.y;
    *z = p.z;
}

void shim_body_get_rotation(uint64_t body, float *x, float *y, float *z, float *w) {
    b3Quat q = b3Body_GetRotation(unpack_body(body));
    *x = q.v.x;
    *y = q.v.y;
    *z = q.v.z;
    *w = q.s;
}

// Runtime body velocity getters (b3Body_GetLinearVelocity / b3Body_GetAngularVelocity).
void shim_body_get_linear_velocity(uint64_t body, float *x, float *y, float *z) {
    b3Vec3 v = b3Body_GetLinearVelocity(unpack_body(body));
    *x = v.x;
    *y = v.y;
    *z = v.z;
}

void shim_body_get_angular_velocity(uint64_t body, float *x, float *y, float *z) {
    b3Vec3 v = b3Body_GetAngularVelocity(unpack_body(body));
    *x = v.x;
    *y = v.y;
    *z = v.z;
}

void shim_body_set_linear_velocity_runtime(uint64_t body, float x, float y, float z) {
    b3Body_SetLinearVelocity(unpack_body(body), (b3Vec3){x, y, z});
}

void shim_body_set_angular_velocity_runtime(uint64_t body, float x, float y, float z) {
    b3Body_SetAngularVelocity(unpack_body(body), (b3Vec3){x, y, z});
}

// Flattens a body's touching contacts into POD that Odin can read. The
// b3ContactData.manifolds pointer is transient (valid only for the current
// step), so the shim reads it here and copies the fields out. POD only —
// no by-value struct ABI crosses the FFI; Odin passes a buffer pointer and
// the shim fills it. Layout must match the Odin Contact_* structs exactly.

#define SHIM_MAX_MANIFOLDS 8
#define SHIM_MAX_MANIFOLD_POINTS 4

typedef struct shim_contact_point {
    float ax, ay, az;       // anchorA (world, relative to bodyA COM)
    float bx, by, bz;       // anchorB (world, relative to bodyB COM)
    float separation;       // negative if penetrating
    float normalImpulse;    // impulse along the manifold normal
    int   triangleIndex;    // height-field/mesh triangle, else -1
} shim_contact_point;

typedef struct shim_contact_manifold {
    float nx, ny, nz;       // world-space normal, points from shape A to B
    int   pointCount;
    shim_contact_point points[SHIM_MAX_MANIFOLD_POINTS];
} shim_contact_manifold;

typedef struct shim_contact_info {
    uint64_t shapeIdA;      // packed shape id
    uint64_t shapeIdB;
    int   manifoldCount;
    shim_contact_manifold manifolds[SHIM_MAX_MANIFOLDS];
} shim_contact_info;

// Returns the number of touching contacts written to `out` (<= max_contacts).
int shim_body_get_contacts(uint64_t body, shim_contact_info *out, int max_contacts) {
    b3BodyId b = unpack_body(body);
    int cap = b3Body_GetContactCapacity(b);
    if (cap <= 0 || max_contacts <= 0) {
        return 0;
    }
    b3ContactData *data = (b3ContactData *)malloc((size_t)cap * sizeof(b3ContactData));
    if (data == NULL) {
        return 0;
    }
    int count = b3Body_GetContactData(b, data, cap);
    int n = count < max_contacts ? count : max_contacts;
    for (int i = 0; i < n; ++i) {
        out[i].shapeIdA = pack_shape(data[i].shapeIdA);
        out[i].shapeIdB = pack_shape(data[i].shapeIdB);
        int mc = data[i].manifoldCount;
        if (mc > SHIM_MAX_MANIFOLDS) mc = SHIM_MAX_MANIFOLDS;
        out[i].manifoldCount = mc;
        for (int j = 0; j < mc; ++j) {
            const b3Manifold *m = &data[i].manifolds[j];
            out[i].manifolds[j].nx = m->normal.x;
            out[i].manifolds[j].ny = m->normal.y;
            out[i].manifolds[j].nz = m->normal.z;
            int pc = m->pointCount;
            if (pc > SHIM_MAX_MANIFOLD_POINTS) pc = SHIM_MAX_MANIFOLD_POINTS;
            out[i].manifolds[j].pointCount = pc;
            for (int k = 0; k < pc; ++k) {
                const b3ManifoldPoint *p = &m->points[k];
                out[i].manifolds[j].points[k].ax = p->anchorA.x;
                out[i].manifolds[j].points[k].ay = p->anchorA.y;
                out[i].manifolds[j].points[k].az = p->anchorA.z;
                out[i].manifolds[j].points[k].bx = p->anchorB.x;
                out[i].manifolds[j].points[k].by = p->anchorB.y;
                out[i].manifolds[j].points[k].bz = p->anchorB.z;
                out[i].manifolds[j].points[k].separation = p->separation;
                out[i].manifolds[j].points[k].normalImpulse = p->normalImpulse;
                out[i].manifolds[j].points[k].triangleIndex = p->triangleIndex;
            }
        }
    }
    free(data);
    return n;
}

void shim_destroy_world(uint64_t world) { b3DestroyWorld(unpack_world(world)); }

// The wheel joint spins body B about local frame B's z-axis and suspends
// it along local frame A's x-axis.

uint64_t shim_create_wheel_joint(uint64_t world,
                                  uint64_t bodyA, uint64_t bodyB,
                                  // local frame A: position + rotation (quat)
                                  float apx, float apy, float apz,
                                  float aqx, float aqy, float aqz, float aqw,
                                  // local frame B: position + rotation (quat)
                                  float bpx, float bpy, float bpz,
                                  float bqx, float bqy, float bqz, float bqw,
                                  int collideConnected,
                                  // suspension
                                  int enableSuspensionSpring,
                                  float suspensionHertz, float suspensionDampingRatio,
                                  int enableSuspensionLimit,
                                  float lowerSuspension, float upperSuspension,
                                  // spin motor
                                  int enableSpinMotor, float maxSpinTorque, float spinSpeed,
                                  // steering
                                  int enableSteering, float steeringHertz,
                                  float steeringDampingRatio, float targetSteeringAngle,
                                  float maxSteeringTorque,
                                  int enableSteeringLimit,
                                  float lowerSteering, float upperSteering,
                                  // structural constraint softness (0 = Box3D defaults)
                                  float constraintHertz, float constraintDampingRatio) {
    b3WheelJointDef def = b3DefaultWheelJointDef();
    def.base.bodyIdA = unpack_body(bodyA);
    def.base.bodyIdB = unpack_body(bodyB);
    def.base.collideConnected = (bool)collideConnected;
    if (constraintHertz > 0.0f) def.base.constraintHertz = constraintHertz;
    if (constraintDampingRatio > 0.0f) def.base.constraintDampingRatio = constraintDampingRatio;
    def.base.localFrameA.p = (b3Vec3){apx, apy, apz};
    def.base.localFrameA.q = (b3Quat){{aqx, aqy, aqz}, aqw};
    def.base.localFrameB.p = (b3Vec3){bpx, bpy, bpz};
    def.base.localFrameB.q = (b3Quat){{bqx, bqy, bqz}, bqw};

    def.enableSuspensionSpring = (bool)enableSuspensionSpring;
    def.suspensionHertz = suspensionHertz;
    def.suspensionDampingRatio = suspensionDampingRatio;
    def.enableSuspensionLimit = (bool)enableSuspensionLimit;
    def.lowerSuspensionLimit = lowerSuspension;
    def.upperSuspensionLimit = upperSuspension;

    def.enableSpinMotor = (bool)enableSpinMotor;
    def.maxSpinTorque = maxSpinTorque;
    def.spinSpeed = spinSpeed;

    def.enableSteering = (bool)enableSteering;
    def.steeringHertz = steeringHertz;
    def.steeringDampingRatio = steeringDampingRatio;
    def.targetSteeringAngle = targetSteeringAngle;
    def.maxSteeringTorque = maxSteeringTorque;
    def.enableSteeringLimit = (bool)enableSteeringLimit;
    def.lowerSteeringLimit = lowerSteering;
    def.upperSteeringLimit = upperSteering;

    b3JointId id = b3CreateWheelJoint(unpack_world(world), &def);
    return pack_joint(id);
}

void shim_wheel_set_spin_motor_speed(uint64_t joint, float speed) {
    b3WheelJoint_SetSpinMotorSpeed(unpack_joint(joint), speed);
}

void shim_wheel_set_target_steering_angle(uint64_t joint, float radians) {
    b3WheelJoint_SetTargetSteeringAngle(unpack_joint(joint), radians);
}

// Achieved (current) wheel steering angle in radians (b3WheelJoint_GetSteeringAngle).
// Steer rate is obtained by finite-differencing this across steps (Box3D
// exposes no steering-rate getter), so the caller keeps the previous value.
float shim_wheel_get_steering_angle(uint64_t joint) {
    return b3WheelJoint_GetSteeringAngle(unpack_joint(joint));
}

// Rigidly connects two bodies with optional damped springs (soft weld).
// hertz 0 = maximum stiffness; damping ratio 1 = critical.

uint64_t shim_create_weld_joint(uint64_t world,
                                uint64_t bodyA, uint64_t bodyB,
                                float apx, float apy, float apz,
                                float aqx, float aqy, float aqz, float aqw,
                                float bpx, float bpy, float bpz,
                                float bqx, float bqy, float bqz, float bqw,
                                int collideConnected,
                                float linearHertz, float angularHertz,
                                float linearDampingRatio, float angularDampingRatio) {
    b3WeldJointDef def = b3DefaultWeldJointDef();
    def.base.bodyIdA = unpack_body(bodyA);
    def.base.bodyIdB = unpack_body(bodyB);
    def.base.collideConnected = (bool)collideConnected;
    def.base.localFrameA.p = (b3Vec3){apx, apy, apz};
    def.base.localFrameA.q = (b3Quat){{aqx, aqy, aqz}, aqw};
    def.base.localFrameB.p = (b3Vec3){bpx, bpy, bpz};
    def.base.localFrameB.q = (b3Quat){{bqx, bqy, bqz}, bqw};

    def.linearHertz = linearHertz;
    def.angularHertz = angularHertz;
    def.linearDampingRatio = linearDampingRatio;
    def.angularDampingRatio = angularDampingRatio;

    b3JointId id = b3CreateWeldJoint(unpack_world(world), &def);
    return pack_joint(id);
}

// Body B slides along local frame A's x-axis (the joint axis) and cannot
// rotate relative to body A.

uint64_t shim_create_prismatic_joint(uint64_t world,
                                     uint64_t bodyA, uint64_t bodyB,
                                     // local frame A: position + rotation (quat)
                                     float apx, float apy, float apz,
                                     float aqx, float aqy, float aqz, float aqw,
                                     // local frame B: position + rotation (quat)
                                     float bpx, float bpy, float bpz,
                                     float bqx, float bqy, float bqz, float bqw,
                                     int collideConnected,
                                     // spring
                                     int enableSpring, float springHertz,
                                     float springDampingRatio, float targetTranslation,
                                     // limit
                                     int enableLimit, float lowerTranslation,
                                     float upperTranslation,
                                     // motor
                                     int enableMotor, float maxMotorForce,
                                     float motorSpeed,
                                     // structural constraint softness (0 = Box3D defaults)
                                     float constraintHertz, float constraintDampingRatio) {
    b3PrismaticJointDef def = b3DefaultPrismaticJointDef();
    def.base.bodyIdA = unpack_body(bodyA);
    def.base.bodyIdB = unpack_body(bodyB);
    if (constraintHertz > 0.0f) def.base.constraintHertz = constraintHertz;
    if (constraintDampingRatio > 0.0f) def.base.constraintDampingRatio = constraintDampingRatio;
    def.base.collideConnected = (bool)collideConnected;
    def.base.localFrameA.p = (b3Vec3){apx, apy, apz};
    def.base.localFrameA.q = (b3Quat){{aqx, aqy, aqz}, aqw};
    def.base.localFrameB.p = (b3Vec3){bpx, bpy, bpz};
    def.base.localFrameB.q = (b3Quat){{bqx, bqy, bqz}, bqw};

    def.enableSpring = (bool)enableSpring;
    def.hertz = springHertz;
    def.dampingRatio = springDampingRatio;
    def.targetTranslation = targetTranslation;
    def.enableLimit = (bool)enableLimit;
    def.lowerTranslation = lowerTranslation;
    def.upperTranslation = upperTranslation;
    def.enableMotor = (bool)enableMotor;
    def.maxMotorForce = maxMotorForce;
    def.motorSpeed = motorSpeed;

    b3JointId id = b3CreatePrismaticJoint(unpack_world(world), &def);
    return pack_joint(id);
}

void shim_prismatic_set_motor_speed(uint64_t joint, float speed) {
    b3PrismaticJoint_SetMotorSpeed(unpack_joint(joint), speed);
}

void shim_prismatic_set_max_motor_force(uint64_t joint, float force) {
    b3PrismaticJoint_SetMaxMotorForce(unpack_joint(joint), force);
}

void shim_prismatic_set_target_translation(uint64_t joint, float translation) {
    b3PrismaticJoint_SetTargetTranslation(unpack_joint(joint), translation);
}

void shim_prismatic_set_spring_hertz(uint64_t joint, float hertz) {
    b3PrismaticJoint_SetSpringHertz(unpack_joint(joint), hertz);
}

void shim_prismatic_set_spring_damping_ratio(uint64_t joint, float damping_ratio) {
    b3PrismaticJoint_SetSpringDampingRatio(unpack_joint(joint), damping_ratio);
}

// Current translation along the joint axis in meters (b3PrismaticJoint_GetTranslation).
float shim_prismatic_get_translation(uint64_t joint) {
    return b3PrismaticJoint_GetTranslation(unpack_joint(joint));
}

// Current translation speed in m/s (b3PrismaticJoint_GetSpeed).
float shim_prismatic_get_speed(uint64_t joint) {
    return b3PrismaticJoint_GetSpeed(unpack_joint(joint));
}

// A point on body B fixed to a point on body A; rotation allowed about
// frame A's z-axis.
uint64_t shim_create_revolute_joint(uint64_t world, uint64_t bodyA, uint64_t bodyB,
                                     float apx, float apy, float apz,
                                     float aqx, float aqy, float aqz, float aqw,
                                     float bpx, float bpy, float bpz,
                                     float bqx, float bqy, float bqz, float bqw,
                                     int collideConnected,
                                     int enableSpring, float springHertz,
                                     float springDampingRatio, float targetAngle,
                                     int enableLimit, float lowerAngle,
                                     float upperAngle,
                                     int enableMotor, float maxMotorTorque,
                                     float motorSpeed,
                                     // structural constraint softness (0 = Box3D defaults)
                                     float constraintHertz, float constraintDampingRatio) {
    b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
    def.base.bodyIdA = unpack_body(bodyA);
    def.base.bodyIdB = unpack_body(bodyB);
    if (constraintHertz > 0.0f) def.base.constraintHertz = constraintHertz;
    if (constraintDampingRatio > 0.0f) def.base.constraintDampingRatio = constraintDampingRatio;
    def.base.collideConnected = (bool)collideConnected;
    def.base.localFrameA.p = (b3Vec3){apx, apy, apz};
    def.base.localFrameA.q = (b3Quat){{aqx, aqy, aqz}, aqw};
    def.base.localFrameB.p = (b3Vec3){bpx, bpy, bpz};
    def.base.localFrameB.q = (b3Quat){{bqx, bqy, bqz}, bqw};

    def.targetAngle = targetAngle;
    def.enableSpring = (bool)enableSpring;
    def.hertz = springHertz;
    def.dampingRatio = springDampingRatio;
    def.enableLimit = (bool)enableLimit;
    def.lowerAngle = lowerAngle;
    def.upperAngle = upperAngle;
    def.enableMotor = (bool)enableMotor;
    def.maxMotorTorque = maxMotorTorque;
    def.motorSpeed = motorSpeed;

    b3JointId id = b3CreateRevoluteJoint(unpack_world(world), &def);
    return pack_joint(id);
}

void shim_revolute_set_motor_speed(uint64_t joint, float speed) {
    b3RevoluteJoint_SetMotorSpeed(unpack_joint(joint), speed);
}

// Current angle in radians relative to the reference (targetAngle at rest).
float shim_revolute_get_angle(uint64_t joint) {
    return b3RevoluteJoint_GetAngle(unpack_joint(joint));
}

// Box3D routes diagnostics (solver "unstable: ...", CCD "CCD stall: ...")
// through b3Log -> b3LogHandler (core.c); the built-in handler prints each
// to stdout.
//
// Per docs/FFI_WASM.md invariant 1, the shim owns the handler functions;
// only the mode (int) crosses the boundary — no callback parameter, since
// an app callback across the FFI would break the wasm dual build
// (Emscripten addFunction plumbing).
//
// Mode 0 replicates Box3D's built-in print rather than b3DefaultLogFcn
// (static in core.c, not exported), so mode 0 == never calling this.
static void shim_default_log( const char* message ) {
    printf( "Box3D: %s\n", message );
}

static void shim_silent_log( const char* message ) {
    (void)message;
}

void shim_set_log_sink( int mode ) {
    b3SetLogFcn( mode == 1 ? shim_silent_log : shim_default_log );
}
