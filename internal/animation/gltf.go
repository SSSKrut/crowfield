package animation

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	rl "github.com/gen2brain/raylib-go/raylib"
)

// gltfNode is the part of a glTF node the loader needs.
type gltfNode struct {
	Name        string      `json:"name"`
	Mesh        *int        `json:"mesh"`
	Skin        *int        `json:"skin"`
	Children    []int       `json:"children"`
	Matrix      []float32   `json:"matrix"`
	Translation *[3]float32 `json:"translation"`
	Rotation    *[4]float32 `json:"rotation"`
	Scale       *[3]float32 `json:"scale"`
}

type gltfDocument struct {
	Nodes  []gltfNode `json:"nodes"`
	Meshes []struct {
		Primitives []struct {
			Mode *int `json:"mode"`
		} `json:"primitives"`
	} `json:"meshes"`
}

// gltfMesh is where raylib took a mesh from: the transform of its node, which
// raylib applies to the vertices, and of the parent node, to which raylib
// attaches a mesh without skin.
type gltfMesh struct {
	skinned bool
	world   rl.Matrix
	// parentWorld is the rest transform of the parent node; hasParent tells
	// whether there is one.
	parentWorld rl.Matrix
	hasParent   bool
}

// gltfMeshes describes the meshes raylib loads from a glTF file, by the
// index raylib gives them: one mesh per triangle primitive, node by node.
func gltfMeshes(path string) ([]gltfMesh, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !strings.HasSuffix(strings.ToLower(path), ".gltf") {
		if data, err = glbJSON(data); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}
	var document gltfDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	parents := make([]int, len(document.Nodes))
	for i := range parents {
		parents[i] = -1
	}
	for i, node := range document.Nodes {
		for _, child := range node.Children {
			if child < 0 || child >= len(parents) {
				return nil, fmt.Errorf("%s: node %d has no child %d", path, i, child)
			}
			parents[child] = i
		}
	}
	var meshes []gltfMesh
	for i, node := range document.Nodes {
		if node.Mesh == nil {
			continue
		}
		if *node.Mesh < 0 || *node.Mesh >= len(document.Meshes) {
			return nil, fmt.Errorf("%s: node %d has no mesh %d", path, i, *node.Mesh)
		}
		mesh := gltfMesh{skinned: node.Skin != nil, world: nodeWorld(document.Nodes, parents, i)}
		if parent := parents[i]; parent >= 0 {
			mesh.parentWorld, mesh.hasParent = nodeWorld(document.Nodes, parents, parent), true
		}
		for _, primitive := range document.Meshes[*node.Mesh].Primitives {
			if primitive.Mode == nil || *primitive.Mode == 4 {
				meshes = append(meshes, mesh)
			}
		}
	}
	return meshes, nil
}

// glbJSON returns the JSON chunk of a binary glTF file.
func glbJSON(data []byte) ([]byte, error) {
	if len(data) < 20 || !bytes.Equal(data[:4], []byte("glTF")) {
		return nil, errors.New("not a binary glTF file")
	}
	length := binary.LittleEndian.Uint32(data[12:16])
	if !bytes.Equal(data[16:20], []byte("JSON")) || uint64(length) > uint64(len(data)-20) {
		return nil, errors.New("binary glTF file without a JSON chunk")
	}
	return data[20 : 20+length], nil
}

func nodeWorld(nodes []gltfNode, parents []int, index int) rl.Matrix {
	world := nodeLocal(&nodes[index])
	for parent := parents[index]; parent >= 0; parent = parents[parent] {
		world = rl.MatrixMultiply(world, nodeLocal(&nodes[parent]))
	}
	return world
}

// nodeLocal is the transform of a node relative to its parent, in raylib's
// convention: MatrixMultiply(a, b) applies a first.
func nodeLocal(node *gltfNode) rl.Matrix {
	if len(node.Matrix) == 16 {
		m := node.Matrix
		return rl.Matrix{
			M0: m[0], M1: m[1], M2: m[2], M3: m[3],
			M4: m[4], M5: m[5], M6: m[6], M7: m[7],
			M8: m[8], M9: m[9], M10: m[10], M11: m[11],
			M12: m[12], M13: m[13], M14: m[14], M15: m[15],
		}
	}
	local := rl.MatrixIdentity()
	if node.Scale != nil {
		local = rl.MatrixScale(node.Scale[0], node.Scale[1], node.Scale[2])
	}
	if node.Rotation != nil {
		r := node.Rotation
		local = rl.MatrixMultiply(local, rl.QuaternionToMatrix(rl.NewQuaternion(r[0], r[1], r[2], r[3])))
	}
	if node.Translation != nil {
		t := node.Translation
		local = rl.MatrixMultiply(local, rl.MatrixTranslate(t[0], t[1], t[2]))
	}
	return local
}
