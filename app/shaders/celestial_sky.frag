#version 460 core
#include "celestial_common.glsl"
// Horizon to J2000 equatorial, by rows.
uniform vec4 eq0;
uniform vec4 eq1;
uniform vec4 eq2;
// NASA's Milky Way with right ascension running right to left from 12h,
// declination +90 at the top.
uniform sampler2D milkyWay;

    void main() {
      vec2 pixel=FlutterFragCoord().xy;
      float r2;
      vec3 h=viewRay(pixel,r2);
      vec3 sky=skyColor(h);
      float day=daylight();

      vec3 e=vec3(dot(eq0.xyz,h),dot(eq1.xyz,h),dot(eq2.xyz,h));
      float ra=atan(e.y,e.x);
      float dec=asin(clamp(e.z,-1.,1.));
      vec2 uv=vec2(fract(.5-ra/6.2831853),.5-dec/3.1415927);
      vec3 band=texture(milkyWay,uv).rgb;
      // Most of the source's reddening reads as orange at this exposure,
      // so the color is kept to about half. A gentle curve keeps the core
      // short of white and the faint outer arms in view.
      float glow=dot(band,vec3(.3,.5,.2));
      vec3 hue=mix(vec3(glow),band,.5)/max(glow,.001);
      sky+=hue*.55*pow(glow,1.15)*look.x*transmission(h)*(1.-day);

      // The Sun's disk, with a bloom that clips to white when the sky is lit.
      float px=pixelDegrees(r2)/DEG;
      float angle=acos(clamp(dot(h,sun.xyz),-1.,1.));
      float radius=look.z;
      float disk=1.-smoothstep(radius-px,radius+px,angle);
      float lowSun=smoothstep(-1.,14.,sun.w);
      vec3 sunTint=mix(vec3(1.,.50,.18),vec3(1.,.97,.90),lowSun);
      // A Sun under the horizon stays hidden even with no ground drawn.
      float above=smoothstep(-1.5,-.5,sun.w);
      disk*=above;
      float bloom=exp(-max(angle-radius,0.)/(radius*1.1))*(.25+.75*day)*above;
      sky+=sunTint*bloom*.9;
      sky=mix(sky,max(sky,sunTint),disk);

      fragColor=vec4(clamp(sky+dither(pixel),0.,1.),1.);
    }
