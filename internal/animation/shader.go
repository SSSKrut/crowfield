package animation

// maxShaderBones bounds the skeleton the skinning shader takes.
const maxShaderBones = 64

// The skinning shader moves every vertex by up to four bone matrices on the
// GPU, so that raylib computes only the matrices on the CPU. Vertex colours
// carry the colours of the merged materials; an alpha of zero marks the
// accent parts, which take the colour the model is drawn with: the team.
const skinningVertexShader = `#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec4 vertexBoneIndices;
in vec4 vertexBoneWeights;

uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 boneMatrices[64];

out vec4 fragColor;
out vec3 fragNormal;

void main()
{
    ivec4 bones = ivec4(vertexBoneIndices);
    mat4 skin = vertexBoneWeights.x*boneMatrices[bones.x] + vertexBoneWeights.y*boneMatrices[bones.y] +
        vertexBoneWeights.z*boneMatrices[bones.z] + vertexBoneWeights.w*boneMatrices[bones.w];
    fragColor = vertexColor;
    fragNormal = mat3(matModel)*(mat3(skin)*vertexNormal);
    gl_Position = mvp*(skin*vec4(vertexPosition, 1.0));
}
`

const skinningFragmentShader = `#version 330
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
