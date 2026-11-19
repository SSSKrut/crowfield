package render

import (
	"fmt"
	"image/color"
	"math"
	"unsafe"

	"ravenfield/internal/physics"

	rl "github.com/gen2brain/raylib-go/raylib"
)

// The lit shader draws vertex colours under the same light as the soldiers.
// A vertex alpha of zero marks accent parts, which take the colour the model
// is drawn with.
const litVertexShader = `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;

uniform mat4 mvp;
uniform mat4 matModel;

out vec4 fragColor;
out vec3 fragNormal;

void main()
{
    fragColor = vertexColor;
    fragNormal = mat3(matModel)*vertexNormal;
    gl_Position = mvp*vec4(vertexPosition, 1.0);
}
`

const litFragmentShader = `#version 330
in vec4 fragColor;
in vec3 fragNormal;

uniform vec4 colDiffuse;

out vec4 finalColor;

void main()
{
    vec3 color = mix(colDiffuse.rgb, fragColor.rgb, fragColor.a);
    float light = 0.6 + 0.4*max(dot(normalize(fragNormal), normalize(vec3(0.4, 1.0, 0.3))), 0.0);
    finalColor = vec4(color*light, 1.0);
}
`

// LoadLitShader loads the shader of box models. Window and graphics must be up.
func LoadLitShader() (rl.Shader, error) {
	shader := rl.LoadShaderFromMemory(litVertexShader, litFragmentShader)
	if !rl.IsShaderValid(shader) {
		return rl.Shader{}, fmt.Errorf("the lit shader did not load")
	}
	return shader, nil
}

// Box is a part of a model built of boxes. Its center and half size are in the
// model's space, where X points right, Y up and Z forward. Pitch tips its
// front up, and then Yaw turns it to the right, in radians.
type Box struct {
	Center physics.Vec3
	Half   physics.Vec3
	Pitch  float32
	Yaw    float32
	Color  color.RGBA
	// Accent parts take the colour the model is drawn with.
	Accent bool
}

// BoxModel is a model of coloured boxes drawn in one call. Its mesh space has
// Z pointing backwards, as OpenGL looks along -Z: Forward turns a point of the
// boxes' space into it.
type BoxModel struct {
	mesh     rl.Mesh
	material rl.Material
	// own is the shader the material came with, which it frees.
	own rl.Shader
}

// Forward turns a point of the space boxes are given in into mesh space.
func Forward(point physics.Vec3) physics.Vec3 {
	return physics.V(point.X, point.Y, -point.Z)
}

// NewBoxModel uploads the boxes as one mesh with flat faces.
func NewBoxModel(boxes []Box, shader rl.Shader) *BoxModel {
	vertices := make([]float32, 0, len(boxes)*36*3)
	normals := make([]float32, 0, len(boxes)*36*3)
	colors := make([]uint8, 0, len(boxes)*36*4)
	for _, box := range boxes {
		center := Forward(box.Center)
		sine, cosine := float32(math.Sin(float64(box.Pitch))), float32(math.Cos(float64(box.Pitch)))
		yawSine, yawCosine := float32(math.Sin(float64(box.Yaw))), float32(math.Cos(float64(box.Yaw)))
		var corners [8]physics.Vec3
		for i := range corners {
			c := Forward(physics.V(
				box.Half.X*float32(i&1*2-1), box.Half.Y*float32(i>>1&1*2-1), box.Half.Z*float32(i>>2&1*2-1),
			))
			// A turn about X by the pitch lifts what points along -Z, and a
			// turn about Y against the yaw takes it to the right.
			c = physics.V(c.X, cosine*c.Y-sine*c.Z, sine*c.Y+cosine*c.Z)
			c = physics.V(yawCosine*c.X-yawSine*c.Z, c.Y, yawSine*c.X+yawCosine*c.Z)
			corners[i] = center.Add(c)
		}
		alpha := uint8(255)
		if box.Accent {
			alpha = 0
		}
		// Every face by its corners in turn; bits 0, 1 and 2 of a corner's
		// index choose its side in X, Y and Z.
		for _, face := range [6][4]int{{0, 2, 6, 4}, {1, 5, 7, 3}, {0, 4, 5, 1}, {2, 3, 7, 6}, {0, 1, 3, 2}, {4, 6, 7, 5}} {
			a, b, c, d := corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]]
			normal := normalize(cross(b.Sub(a), c.Sub(a)))
			middle := a.Add(c).Mul(0.5)
			if normal.Dot(middle.Sub(center)) < 0 {
				// Wound the other way: the face would look inwards.
				b, d, normal = d, b, normal.Mul(-1)
			}
			for _, v := range [6]physics.Vec3{a, b, c, a, c, d} {
				vertices = append(vertices, v.X, v.Y, v.Z)
				normals = append(normals, normal.X, normal.Y, normal.Z)
				colors = append(colors, box.Color.R, box.Color.G, box.Color.B, alpha)
			}
		}
	}
	mesh := rl.Mesh{
		VertexCount: int32(len(vertices) / 3), TriangleCount: int32(len(vertices) / 9),
		Vertices: unsafe.SliceData(vertices), Normals: unsafe.SliceData(normals), Colors: unsafe.SliceData(colors),
	}
	rl.UploadMesh(&mesh, false)
	// Drawing needs only the buffers on the GPU; the mesh keeps no Go memory.
	mesh.Vertices, mesh.Normals, mesh.Colors = nil, nil, nil
	material := rl.LoadMaterialDefault()
	own := material.Shader
	material.Shader = shader
	return &BoxModel{mesh: mesh, material: material, own: own}
}

// Draw draws the model moved by transform, its accent parts in tint.
func (m *BoxModel) Draw(transform rl.Matrix, tint color.RGBA) {
	m.material.GetMap(rl.MapDiffuse).Color = tint
	rl.DrawMesh(m.mesh, m.material, transform)
}

// Close frees the mesh; the shader belongs to the caller.
func (m *BoxModel) Close() {
	rl.UnloadMesh(&m.mesh)
	m.material.Shader = m.own
	rl.UnloadMaterial(m.material)
}
