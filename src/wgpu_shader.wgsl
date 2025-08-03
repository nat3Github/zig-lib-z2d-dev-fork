// shader.wgsl
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
};
struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) fragment_color: vec4<f32>,   // <-- CORRECT: Pass color as vec4<f32>
};

@vertex
fn vertex_shader(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4f(in.position, 0.0, 1.0);
    out.fragment_color = in.color;
    return out;
}

// The Fragment Shader
@fragment
fn fragment_shader(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.fragment_color;
}


///okk
struct VertexOutput2 {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>, // Inter-stage variable for color
};

@vertex
fn vertex_shader2(
    @location(0) in_position: vec2<f32>,
    @location(1) in_color: vec4<f32>
) -> VertexOutput2 {
    var output: VertexOutput2;
    output.position = vec4<f32>(in_position, 0.0, 1.0);
    output.color = in_color; // Pass the normalized color directly to the fragment shader
    return output;
}

@fragment
fn fragment_shader2(in: VertexOutput2) -> @location(0) vec4<f32> {
    return in.color; // Use the interpolated color from the vertex shader
}