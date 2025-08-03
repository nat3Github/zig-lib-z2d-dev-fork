// shader.wgsl
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>, // Inter-stage variable for color
};

@vertex
fn vertex_shader2(in: VertexInput) -> VertexOutput {
    var output: VertexOutput;

    let screen_width: f32 = 300.0;
    let screen_height: f32 = 300.0;

    let ndc_x = (in.position.x / screen_width) * 2.0 - 1.0;
    let ndc_y = 1.0 - (in.position.y / screen_height) * 2.0; // Assuming Y=0 is top, Y=300 is bottom

    output.position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0); // Z=0, W=1 for 2D rendering
    output.color = in.color; // Pass the normalized color directly to the fragment shader
    return output;
}

@fragment
fn fragment_shader2(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color; // Use the interpolated color from the vertex shader
}




