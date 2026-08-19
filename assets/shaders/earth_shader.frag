#version 320 es
#include <flutter/runtime_effect.glsl>

// 3D textured earth with day/night lighting
// Textures: equirectangular, public domain, no borders
uniform sampler2D uDay;
uniform sampler2D uNight;
uniform float uRot;   // rotation angle (radians)
uniform float uTilt;  // axial tilt (radians)
uniform vec2 uSize;   // canvas size (pixels)

out vec4 frag_color;

void main() {
  vec2 p = FlutterFragCoord().xy / uSize;
  vec2 d = p - vec2(0.5, 0.5);
  float R = 0.42;
  float r = length(d);

  // atmosphere glow
  if (r > R * 1.18) {
    frag_color = vec4(0.0, 0.0, 0.0, 0.0);
    return;
  }
  if (r > R) {
    float t = (r - R) / (R * 0.18);
    float glow = pow(1.0 - t, 2.0);
    frag_color = vec4(vec3(0.45, 0.68, 1.0) * glow * 0.5, glow);
    return;
  }

  // sphere normal in view space (z toward viewer)
  float z = sqrt(max(0.0, R * R - r * r));
  vec3 n = normalize(vec3(d.x, d.y, z));

  // rotation around Y axis
  float cr = cos(uRot);
  float sr = sin(uRot);
  vec3 nr = vec3(n.x * cr - n.z * sr, n.y, n.x * sr + n.z * cr);
  // axial tilt around X axis
  float ct = cos(uTilt);
  float st = sin(uTilt);
  vec3 ns = vec3(nr.x, nr.y * ct - nr.z * st, nr.y * st + nr.z * ct);

  // lat/lon to equirectangular UV (top of texture = north pole, x=0 = -180)
  float lat = 0.5 - asin(ns.y) / 3.14159265358979;
  float lon = atan(ns.x, ns.z) / (2.0 * 3.14159265358979) + 0.5;
  vec2 tex = vec2(lon, lat);

  // sample day / night textures
  vec4 day = texture(uDay, tex);
  vec4 night = texture(uNight, tex);

  // sun direction (fixed, upper-left) -> day/night mixing
  vec3 sun = normalize(vec3(0.35, 0.30, 0.88));
  float lambert = dot(ns, sun);
  float dayMix = clamp(lambert * 3.0 + 0.5, 0.0, 1.0);
  vec4 col = mix(night, day, dayMix);

  // faint blue night-side fill
  col.rgb += vec3(0.02, 0.035, 0.07) * (1.0 - dayMix);

  // specular highlight
  vec3 viewDir = normalize(vec3(0.0, 0.0, 1.0));
  float spec = pow(max(dot(ns, normalize(sun + viewDir)), 0.0), 40.0) * 0.35;
  col.rgb += vec3(spec);

  // rim darkening for depth
  float rim = smoothstep(0.0, 1.0, r / R);
  col.rgb *= mix(1.0, 0.62, rim * rim);

  frag_color = vec4(col.rgb, 1.0);
}
