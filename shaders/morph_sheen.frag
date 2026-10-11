#version 460 core

// Sheen overlay for MorphOS-UI fields. Drawn over the node mesh with vertex
// colours carrying each node's alpha (BlendMode.modulate), so the light only
// lands on nodes.

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;      // field size in local pixels
uniform vec2 uLight;     // pointer position in local pixels
uniform float uTime;     // seconds of animation time
uniform float uIntensity;

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;
  float extent = max(max(uSize.x, uSize.y), 1.0);
  float d = distance(p, uLight) / extent;
  float glow = exp(-d * 5.0);
  float band = 0.5 + 0.5 * sin((p.x + p.y) / extent * 9.0 - uTime * 1.6);
  float a = clamp((glow * 0.55 + band * 0.12) * uIntensity, 0.0, 1.0);
  fragColor = vec4(a, a, a, a);
}
