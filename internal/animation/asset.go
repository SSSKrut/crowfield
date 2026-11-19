package animation

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"image/color"
	"math"
	"strings"
	"unsafe"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

const (
	// characterModelHeight is the height of the soldier capsule of the
	// default tuning, from the soles to the top of the head.
	characterModelHeight = float32(1.8)
	// raylib samples glTF clips at this rate; the last keyframe of a looping
	// clip repeats the first.
	keyframeRate = 60
)

// Clip is an animation a soldier plays.
type Clip int

const (
	ClipIdle Clip = iota
	ClipWalking
	ClipRunning
	clipCount
)

var clipNames = [clipCount]string{"Idle", "Walking", "Running"}

func (c Clip) String() string {
	return clipNames[c]
}

type clip struct {
	animation rl.ModelAnimation
	// first is the index of the clip's first keyframe in the pose cache;
	// frames excludes the closing keyframe that repeats the first.
	first, frames int
}

// CharacterAsset is a character model loaded once and shared by every soldier
// drawn with it: one merged mesh skinned on the GPU, the skeleton, the clips,
// and the bone matrices of every keyframe of the clips, computed at load.
type CharacterAsset struct {
	model       rl.Model
	animations  []rl.ModelAnimation
	shader      rl.Shader
	clips       [clipCount]clip
	bones       map[string]int
	inverseBind []rl.Matrix
	// poses holds boneCount matrices per keyframe of every clip, in C memory
	// so that a draw can point the model at them.
	poses  []rl.Matrix
	accent color.RGBA
	scale  float32
	origin physics.Vec3
	// bounds is the box around the standing model, in metres, feet at zero.
	bounds rl.BoundingBox
}

// LoadCharacterAsset loads a skinned glTF model. Window and graphics must be
// up.
func LoadCharacterAsset(path string) (*CharacterAsset, error) {
	model := rl.LoadModel(path)
	if model.MeshCount == 0 || model.Skeleton.BoneCount == 0 {
		rl.UnloadModel(model)
		return nil, fmt.Errorf("model %q has no mesh or skeleton", path)
	}
	a := &CharacterAsset{model: model, bones: make(map[string]int)}
	if err := a.load(path); err != nil {
		a.Close()
		return nil, fmt.Errorf("model %q: %w", path, err)
	}
	return a, nil
}

func (a *CharacterAsset) load(path string) error {
	boneCount := int(a.model.Skeleton.BoneCount)
	if boneCount > maxShaderBones {
		return fmt.Errorf("%d bones, the skinning shader takes %d", boneCount, maxShaderBones)
	}
	meshes, err := gltfMeshes(path)
	if err != nil {
		return err
	}
	if err := a.toBindSpace(meshes); err != nil {
		return err
	}
	a.shader = rl.LoadShaderFromMemory(skinningVertexShader, skinningFragmentShader)
	locations := unsafe.Slice(a.shader.Locs, rl.MaxShaderLocations)
	if !rl.IsShaderValid(a.shader) || locations[rl.ShaderLocVertexBoneids] < 0 ||
		locations[rl.ShaderLocVertexBonetransforms] < 0 {
		return fmt.Errorf("the skinning shader did not load")
	}
	if err := a.mergeMeshes(); err != nil {
		return err
	}
	for i, bone := range a.model.Skeleton.GetBones() {
		a.bones[boneName(bone)] = i
	}
	a.inverseBind = make([]rl.Matrix, boneCount)
	for i, bind := range a.model.Skeleton.GetBindPose() {
		a.inverseBind[i] = rl.MatrixInvert(matrixFromRaylib(bind))
	}
	a.animations = rl.LoadModelAnimations(path)
	frames := 0
	for i := range a.clips {
		found := false
		for _, animation := range a.animations {
			if strings.EqualFold(animation.GetName(), clipNames[i]) && animation.KeyframeCount > 1 &&
				int(animation.BoneCount) == boneCount {
				a.clips[i] = clip{animation: animation, first: frames, frames: int(animation.KeyframeCount) - 1}
				frames += a.clips[i].frames
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("animation %q not found", clipNames[i])
		}
	}
	a.poses = cArray[rl.Matrix](frames * boneCount)
	for i := range a.clips {
		c := &a.clips[i]
		for frame := range c.frames {
			rl.UpdateModelAnimation(a.model, c.animation, float32(frame))
			copy(a.poses[(c.first+frame)*boneCount:], a.model.GetBoneMatrices())
		}
	}
	return a.measure()
}

// toBindSpace puts every mesh where the skinning expects it: in the bind pose
// of the skeleton, which raylib takes from the inverse bind matrices.
//
// raylib moves the vertices of every mesh by the transform of its node. glTF
// says to ignore that transform for a skinned mesh, whose vertices are
// already in bind space; the robot's hands were drawn a hundred times too
// large, far from the body. A mesh without skin under a bone node, like the
// robot's arms and legs, raylib binds to that bone, but leaves it in the rest
// pose of the bone, which need not be its bind pose.
func (a *CharacterAsset) toBindSpace(sources []gltfMesh) error {
	meshes := a.model.GetMeshes()
	if len(sources) != len(meshes) {
		return fmt.Errorf("raylib loaded %d meshes, the file has %d", len(meshes), len(sources))
	}
	bindPose := a.model.Skeleton.GetBindPose()
	for i, source := range sources {
		mesh := &meshes[i]
		var move rl.Matrix
		switch {
		case source.skinned:
			move = rl.MatrixInvert(source.world)
		case source.hasParent && mesh.BoneIndices != nil:
			bone := int(unsafe.Slice(mesh.BoneIndices, 1)[0])
			move = rl.MatrixMultiply(rl.MatrixInvert(source.parentWorld), matrixFromRaylib(bindPose[bone]))
		default:
			continue
		}
		normal := rl.MatrixTranspose(rl.MatrixInvert(move))
		count := int(mesh.VertexCount)
		vertices := unsafe.Slice(mesh.Vertices, 3*count)
		for k := 0; k < len(vertices); k += 3 {
			v := rl.Vector3Transform(rl.NewVector3(vertices[k], vertices[k+1], vertices[k+2]), move)
			vertices[k], vertices[k+1], vertices[k+2] = v.X, v.Y, v.Z
		}
		if mesh.Normals != nil {
			normals := unsafe.Slice(mesh.Normals, 3*count)
			for k := 0; k < len(normals); k += 3 {
				n := rl.Vector3Normalize(rl.Vector3Transform(rl.NewVector3(normals[k], normals[k+1], normals[k+2]), normal))
				normals[k], normals[k+1], normals[k+2] = n.X, n.Y, n.Z
			}
		}
	}
	return nil
}

// measure scales the model to the soldier height and puts its soles at the
// origin, from the mesh standing in the first keyframe of the idle clip.
func (a *CharacterAsset) measure() error {
	mesh := a.model.GetMeshes()[0]
	count := int(mesh.VertexCount)
	vertices := unsafe.Slice(mesh.Vertices, 3*count)
	bones := unsafe.Slice(mesh.BoneIndices, 4*count)
	weights := unsafe.Slice(mesh.BoneWeights, 4*count)
	pose := a.poses[a.clips[ClipIdle].first*int(a.model.Skeleton.BoneCount):]
	low := rl.NewVector3(math.MaxFloat32, math.MaxFloat32, math.MaxFloat32)
	high := rl.NewVector3(-math.MaxFloat32, -math.MaxFloat32, -math.MaxFloat32)
	for v := range count {
		vertex := rl.NewVector3(vertices[3*v], vertices[3*v+1], vertices[3*v+2])
		var skinned rl.Vector3
		for k := 4 * v; k < 4*v+4; k++ {
			skinned = rl.Vector3Add(skinned, rl.Vector3Scale(rl.Vector3Transform(vertex, pose[bones[k]]), weights[k]))
		}
		low, high = rl.Vector3Min(low, skinned), rl.Vector3Max(high, skinned)
	}
	if high.Y <= low.Y {
		return fmt.Errorf("the model has no height")
	}
	a.scale = characterModelHeight / (high.Y - low.Y)
	a.origin = physics.V(0, -low.Y*a.scale, 0)
	lift := rl.NewVector3(0, -low.Y, 0)
	a.bounds = rl.BoundingBox{
		Min: rl.Vector3Scale(rl.Vector3Add(low, lift), a.scale), Max: rl.Vector3Scale(rl.Vector3Add(high, lift), a.scale),
	}
	return nil
}

// mergeMeshes joins every mesh into one with the material colours in its
// vertices, so a soldier is one draw call, and gives it the skinning shader.
// The most saturated colour becomes the accent, drawn in the team colour.
func (a *CharacterAsset) mergeMeshes() error {
	meshes := a.model.GetMeshes()
	materials := a.model.GetMaterials()
	meshMaterial := unsafe.Slice(a.model.MeshMaterial, a.model.MeshCount)
	vertexCount, indexCount := 0, 0
	for i := range meshes {
		if meshes[i].BoneIndices == nil || meshes[i].BoneWeights == nil {
			return fmt.Errorf("mesh %d is not bound to the skeleton", i)
		}
		vertexCount += int(meshes[i].VertexCount)
		indexCount += 3 * int(meshes[i].TriangleCount)
	}
	if vertexCount > 1<<16 {
		return fmt.Errorf("%d vertices do not fit 16-bit indices", vertexCount)
	}
	saturation := func(c color.RGBA) int { return int(max(c.R, c.G, c.B)) - int(min(c.R, c.G, c.B)) }
	for i := range meshes {
		if c := diffuse(materials, meshMaterial[i]); saturation(c) > saturation(a.accent) {
			a.accent = c
		}
	}
	merged := rl.Mesh{VertexCount: int32(vertexCount), TriangleCount: int32(indexCount / 3)}
	vertices := cArray[float32](3 * vertexCount)
	normals := cArray[float32](3 * vertexCount)
	colors := cArray[uint8](4 * vertexCount)
	boneIndices := cArray[uint8](4 * vertexCount)
	boneWeights := cArray[float32](4 * vertexCount)
	indices := cArray[uint16](indexCount)
	base, next := 0, 0
	for i := range meshes {
		mesh := &meshes[i]
		count := int(mesh.VertexCount)
		copy(vertices[3*base:], unsafe.Slice(mesh.Vertices, 3*count))
		if mesh.Normals != nil {
			copy(normals[3*base:], unsafe.Slice(mesh.Normals, 3*count))
		}
		copy(boneIndices[4*base:], unsafe.Slice(mesh.BoneIndices, 4*count))
		copy(boneWeights[4*base:], unsafe.Slice(mesh.BoneWeights, 4*count))
		c := diffuse(materials, meshMaterial[i])
		alpha := uint8(255)
		if c == a.accent {
			alpha = 0
		}
		for v := base; v < base+count; v++ {
			colors[4*v], colors[4*v+1], colors[4*v+2], colors[4*v+3] = c.R, c.G, c.B, alpha
		}
		triangles := 3 * int(mesh.TriangleCount)
		if mesh.Indices != nil {
			for k, index := range unsafe.Slice(mesh.Indices, triangles) {
				indices[next+k] = uint16(base + int(index))
			}
		} else {
			for k := range triangles {
				indices[next+k] = uint16(base + k)
			}
		}
		base += count
		next += triangles
	}
	merged.Vertices, merged.Normals, merged.Colors = &vertices[0], &normals[0], &colors[0]
	merged.BoneIndices, merged.BoneWeights, merged.Indices = &boneIndices[0], &boneWeights[0], &indices[0]
	merged.BoneCount = a.model.Skeleton.BoneCount
	for i := range meshes {
		rl.UnloadMesh(&meshes[i])
	}
	meshes[0] = merged
	a.model.MeshCount = 1
	meshMaterial[0] = 0
	rl.UploadMesh(&meshes[0], false)
	materials[0].Shader = a.shader
	materials[0].GetMap(rl.MapDiffuse).Color = rl.White
	return nil
}

// Close frees the model. Characters drawn with it must not be used after.
func (a *CharacterAsset) Close() {
	if a.poses != nil {
		C.free(unsafe.Pointer(&a.poses[0]))
		a.poses = nil
	}
	if a.animations != nil {
		rl.UnloadModelAnimations(a.animations)
		a.animations = nil
	}
	if a.shader.ID != 0 {
		rl.UnloadShader(a.shader)
		a.shader = rl.Shader{}
	}
	rl.UnloadModel(a.model)
	a.model = rl.Model{}
}

// BoneNames lists the bones of the skeleton.
func (a *CharacterAsset) BoneNames() []string {
	names := make([]string, 0, len(a.bones))
	for _, bone := range a.model.Skeleton.GetBones() {
		names = append(names, boneName(bone))
	}
	return names
}

// Bounds is the box around the standing model, in metres, feet at zero.
func (a *CharacterAsset) Bounds() rl.BoundingBox {
	return a.bounds
}

// Accent is the colour of the parts drawn in the team colour; drawing with
// it shows the model as it was made.
func (a *CharacterAsset) Accent() color.RGBA {
	return a.accent
}

// draw draws the model with the given bone matrices, which must be in C
// memory: raylib uploads them to the shader.
func (a *CharacterAsset) draw(matrices *rl.Matrix, position physics.Vec3, yaw physics.Quat, tint color.RGBA) {
	model := a.model
	model.BoneMatrices = matrices
	rl.DrawModelEx(
		model, vector(position.Add(a.origin)), rl.NewVector3(0, 1, 0), yawAngle(yaw),
		rl.NewVector3(a.scale, a.scale, a.scale), tint,
	)
}

func (a *CharacterAsset) cachedPose(c Clip, time float32) *rl.Matrix {
	clip := &a.clips[c]
	frame := int(time*keyframeRate+0.5) % clip.frames
	return &a.poses[(clip.first+frame)*int(a.model.Skeleton.BoneCount)]
}

func diffuse(materials []rl.Material, index int32) color.RGBA {
	if index < 0 || int(index) >= len(materials) || materials[index].Maps == nil {
		return rl.White
	}
	return materials[index].GetMap(rl.MapDiffuse).Color
}

// cArray allocates a zeroed array in C memory, which raylib may keep and free.
func cArray[T any](count int) []T {
	var zero T
	memory := C.calloc(C.size_t(max(1, count)), C.size_t(unsafe.Sizeof(zero)))
	if memory == nil {
		panic("out of memory")
	}
	return unsafe.Slice((*T)(memory), count)
}
