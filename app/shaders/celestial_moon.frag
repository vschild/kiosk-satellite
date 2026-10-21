#version 460 core
#include <flutter/runtime_effect.glsl>
uniform vec4 disk;    // center x, center y, radius in pixels, rotation of lunar north
uniform vec4 light;   // sunlight direction seen from the Moon, w: earthshine
uniform vec4 tint;    // rgb: air color, w: daylight
uniform sampler2D moonMap;
out vec4 fragColor;

    void main() {
      vec2 p=(FlutterFragCoord().xy-disk.xy)/disk.z;
      p.y=-p.y;
      float r=length(p);
      float edge=1.-smoothstep(1.-1.2/disk.z,1.+.6/disk.z,r);
      if(edge<=0.) {
        fragColor=vec4(0.);
        return;
      }
      vec2 q=min(r,1.)*normalize(p+vec2(1e-6,0.));
      vec3 n=vec3(q,sqrt(max(0.,1.-dot(q,q))));
      float c=cos(disk.w), s=sin(disk.w);
      vec2 t=vec2(c*q.x+s*q.y,-s*q.x+c*q.y);
      vec3 albedo=texture(moonMap,clamp(t*vec2(.5,-.5)+.5,0.,1.)).rgb;
      vec3 l=normalize(light.xyz);
      float mu0=max(dot(n,l),0.);
      float mu=max(n.z,.05);
      // Lommel-Seeliger keeps the full Moon flat to the limb, a little
      // Lambert softens the terminator.
      float lit=mix(2.*mu0/(mu0+mu),mu0,.25);
      lit*=smoothstep(-.06,.10,dot(n,l));
      vec3 color=albedo*1.25*lit*tint.rgb+albedo*light.w;
      float day=tint.w;
      // By day the unlit side vanishes into the blue.
      float alpha=edge*mix(1.,clamp(lit*.9,0.,.85),day);
      color=mix(color,color*.9+vec3(.08,.10,.14)*lit,day);
      fragColor=vec4(clamp(color,0.,1.)*alpha,alpha);
    }
