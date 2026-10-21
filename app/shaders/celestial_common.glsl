#include <flutter/runtime_effect.glsl>
// Shared by the Celestial sky and terrain. Directions are horizon vectors:
// x east, y north, z up. The view is a stereographic projection centered on
// view.xy (pixels) with view.z pixels per unit of the projection plane.
// Impeller pads vec3 uniforms to four floats, so vectors travel as vec4.
uniform vec4 view;      // center x, center y, scale, dither strength
uniform vec4 camRight;  // camera axes in horizon coordinates
uniform vec4 camUp;
uniform vec4 camForward; // w: 1 with no landscape
uniform vec4 sun;       // direction, w: altitude in degrees
uniform vec4 moon;      // direction, w: moonlight on the sky, 0 to 1
uniform vec4 look;      // x: Milky Way, y: daylight allowed, z: Sun radius in radians, w: light pollution
out vec4 fragColor;

    const float DEG=57.29578;

    vec3 viewRay(vec2 pixel, out float r2) {
      vec2 q=vec2(pixel.x-view.x,view.y-pixel.y)/view.z;
      r2=dot(q,q);
      vec3 d=vec3(4.*q.x,4.*q.y,4.-r2)/(4.+r2);
      return normalize(d.x*camRight.xyz+d.y*camUp.xyz+d.z*camForward.xyz);
    }

    // Degrees covered by one pixel at this distance from the center.
    float pixelDegrees(float r2) {
      return 4./(4.+r2)/view.z*DEG;
    }

    // Interleaved gradient noise, to dither the dark gradients.
    vec3 dither(vec2 pixel) {
      return vec3(fract(52.9829189*fract(dot(pixel,vec2(.06711056,.00583715))))-.5)*view.w/255.;
    }

    // The Sun's altitude the sky follows. With daylight off the sky stays
    // dark whatever the hour.
    float skySun() {
      return look.y>.5 ? sun.w : min(sun.w,-24.);
    }

    float daylight() {
      return smoothstep(-5.,10.,skySun());
    }

    // Sky color toward h, before stars. Display referred.
    vec3 skyColor(vec3 h) {
      float s=skySun();
      // With no landscape the sky below the horizon mirrors the one above,
      // so there is no edge along the horizon line.
      float up=camForward.w>.5 ? abs(h.z) : max(h.z,0.);
      float horizon=pow(1.-up,3.5);
      float cosSun=dot(h,sun.xyz);
      vec2 level=normalize(h.xy+vec2(1e-5,0.));
      vec2 sunLevel=normalize(sun.xy+vec2(1e-5,0.));
      float towardSun=dot(level,sunLevel)*.5+.5;

      // Night: airglow and distant towns lift the horizon a little.
      vec3 night=mix(vec3(.0035,.0052,.0115),vec3(.040,.044,.056),horizon);
      // City glow: sodium and LED light scattered back down, strongest low.
      night+=vec3(.105,.085,.065)*look.w*(.30+.70*horizon);

      // Twilight: deep blue overhead, warm along the horizon toward the Sun
      // and the pink belt with the Earth's shadow opposite it.
      float glow=smoothstep(-18.,-8.,s);
      float civil=smoothstep(-10.,1.,s);
      vec3 twilightSky=mix(vec3(.018,.035,.10),vec3(.10,.14,.28),horizon)*glow;
      twilightSky=mix(twilightSky,mix(vec3(.08,.12,.30),vec3(.42,.46,.60),horizon),civil);
      float band=pow(1.-up,7.)*(.12+.88*pow(towardSun,4.));
      float deep=smoothstep(-16.,-4.,s);
      vec3 warm=mix(vec3(.62,.24,.08),vec3(1.,.58,.26),civil);
      twilightSky+=warm*band*deep*(.45+.55*civil);
      float belt=pow(1.-up,5.)*pow(1.-towardSun,3.)*civil*(1.-smoothstep(2.,8.,s));
      twilightSky+=vec3(.30,.18,.26)*belt*.6;
      float twilightWeight=smoothstep(-19.,-12.,s)*(1.-smoothstep(6.,14.,s));

      // Day: deep blue overhead, paling toward the horizon and the Sun.
      vec3 day=mix(vec3(.19,.37,.72),vec3(.66,.76,.88),horizon);
      day=mix(day,vec3(.96,.86,.70),pow(1.-up,6.)*(1.-smoothstep(4.,25.,s))*pow(towardSun,2.)*.6);

      vec3 sky=mix(night,night+twilightSky,twilightWeight);
      sky=mix(sky,day,daylight());

      // Forward scattering around the Sun, when the sky is lit.
      float lit=smoothstep(-8.,4.,s);
      float aureole=pow(max(cosSun,0.),24.)*.30+pow(max(cosSun,0.),3.)*.10;
      sky+=mix(vec3(1.,.62,.32),vec3(1.,.96,.88),daylight())*aureole*lit;

      // Moonlight: a blue lift over the whole sky and a glow round the Moon.
      float m=moon.w*(1.-daylight());
      float cosMoon=dot(h,moon.xyz);
      sky+=vec3(.020,.032,.060)*m*(.5+.5*horizon);
      sky+=vec3(.75,.80,.88)*m*(pow(max(cosMoon,0.),900.)*.30+pow(max(cosMoon,0.),60.)*.06+pow(max(cosMoon,0.),8.)*.025);
      return sky;
    }

    // How much of the starlight reaches the eye through the air.
    float transmission(vec3 h) {
      if(camForward.w>.5) return 1.;
      float alt=max(asin(clamp(h.z,-1.,1.))*DEG,0.);
      float airmass=1./(sin(alt/DEG)+.50572*pow(alt+6.07995,-1.6364));
      return exp(-.23*(airmass-1.));
    }
