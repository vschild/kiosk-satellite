#version 460 core
#include "celestial_common.glsl"
uniform vec4 groundNear;  // daylit color of the near ground
uniform vec4 groundFar;   // daylit color of the far ridges
// The horizon around the observer: row 0 the near ridge, row 1 the far
// one. Each texel holds a height in 16 bits, red high and green low, from
// -2 to 14 degrees across 360 degrees of azimuth.
uniform sampler2D profile;

    float ridge(float u, float row) {
      vec2 rg=texture(profile,vec2(u,row)).rg;
      return dot(rg,vec2(65280.,255.))/65535.*16.-2.;
    }

    float hash(vec2 p) {
      return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);
    }

    float noise(vec2 p) {
      vec2 i=floor(p), f=fract(p);
      f=f*f*(3.-2.*f);
      return mix(mix(hash(i),hash(i+vec2(1.,0.)),f.x),
        mix(hash(i+vec2(0.,1.)),hash(i+vec2(1.,1.)),f.x),f.y);
    }

    void main() {
      vec2 pixel=FlutterFragCoord().xy;
      float r2;
      vec3 h=viewRay(pixel,r2);
      float alt=asin(clamp(h.z,-1.,1.))*DEG;
      float az=atan(h.x,h.y)*DEG;
      float u=fract(az/360.);
      float near=ridge(u,.25);
      float far=ridge(u,.75);
      float px=pixelDegrees(r2);
      float nearCover=clamp((near-alt)/px+.5,0.,1.);
      float farCover=clamp((far-alt)/px+.5,0.,1.);
      if(nearCover+farCover<=0.) {
        fragColor=vec4(0.);
        return;
      }
      float s=skySun();
      float day=daylight();
      float dusk=smoothstep(-16.,0.,s)*(1.-day);
      float moonlight=moon.w*(1.-day)*smoothstep(-2.,10.,asin(clamp(moon.z,-1.,1.))*DEG);
      float ambient=mix(.012+.10*dusk+.05*moonlight+.06*look.w,1.,day);

      // The air between here and the ridges takes the color of the sky
      // behind them, so a ridge is always darker than the sky it covers.
      vec3 haze=skyColor(normalize(vec3(h.xy,max(h.z,.009)*length(h.xy))));

      float grain=noise(vec2(az*2.,alt*2.))*.6+noise(vec2(az*7.,alt*7.))*.4;
      // Distant ridges pale into the sky, and lighten toward their tops.
      float rise=clamp((alt+1.)/(far+1.),0.,1.);
      vec3 farColor=mix(groundFar.rgb*ambient,haze,mix(.30,.50,day)+.10*rise);
      farColor*=.94+.10*grain;
      float depth=smoothstep(0.,-25.,alt);
      vec3 nearColor=groundNear.rgb*ambient*(.90+.18*grain)*(1.-.40*depth);
      nearColor=mix(nearColor,haze*.6,.06*(1.-depth));

      float alpha=nearCover+farCover*(1.-nearCover);
      vec3 color=nearColor*nearCover+farColor*farCover*(1.-nearCover);
      fragColor=vec4(clamp(color+dither(pixel)*alpha,0.,1.),alpha);
    }
