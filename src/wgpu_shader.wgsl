// wgpu_shader.wgsl
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
};

// Define the struct for the uniform buffer first
struct ScreenUniforms {
    screen_size: vec2<f32>,
};

@group(0) @binding(0)
var<uniform> screen_uniforms: ScreenUniforms;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vertex_shader2(in: VertexInput) -> VertexOutput {
    var output: VertexOutput;

    let screen_width: f32 = screen_uniforms.screen_size.x;
    let screen_height: f32 = screen_uniforms.screen_size.y;

    let ndc_x = (in.position.x / screen_width) * 2.0 - 1.0;
    let ndc_y = 1.0 - (in.position.y / screen_height) * 2.0;

    output.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
    output.color = in.color;
    return output;
}

@fragment
fn fragment_shader2(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color;
}
