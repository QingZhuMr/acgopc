#version 320 es
#include <flutter/runtime_effect.glsl>

// Minecraft-style planet: single procedural surface texture mapped onto sphere.
// Float uniforms (indices 0..6): uRot, uSize.x/y, uGlowColor.r/g/b, uGlowStrength.
// Sampler uniforms (index 0): uSurface.

uniform float uRot;
uniform vec2 uSize;
uniform vec3 uGlowColor;
uniform float uGlowStrength;
uniform sampler2D uSurface;

out vec4 frag_color;

void main() {
  vec2 p = FlutterFragCoord().xy / uSize;
  vec2 d = p - vec2(0.5, 0.5);
  float R = 0.42;
  float r = length(d);

  // atmosphere glow (only in front)
  if (r > R * 1.18) {
    frag_color = vec4(0.0, 0.0, 0.0, 0.0);
    return;
  }
  if (r > R) {
    float t = (r - R) / (R * 0.18);
    float glow = pow(1.0 - t, 2.0);
    frag_color = vec4(uGlowColor * glow * uGlowStrength, glow);
    return;
  }

  // sphere normal (z toward viewer), screen y grows DOWN so negate d.y
  float z = sqrt(max(0.0, R * R - r * r));
  vec3 n = normalize(vec3(d.x, -d.y, z));

  // rotation around Y axis (no axial tilt)
  float cr = cos(uRot);
  float sr = sin(uRot);
  vec3 ns = vec3(n.x * cr - n.z * sr, n.y, n.x * sr + n.z * cr);

  // equirectangular UV
  float lat = 0.5 - asin(ns.y) / 3.14159265358979;
  float lon = atan(ns.x, ns.z) / (2.0 * 3.14159265358979) + 0.5;
  vec2 tex = vec2(lon, lat);

  vec4 col = texture(uSurface, tex);
  frag_color = vec4(col.rgb, 1.0);
}
