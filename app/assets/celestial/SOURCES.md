# Celestial sky data

Built by `tool/generate_celestial_assets.py`. Regenerate with that script
rather than editing these files.

| File | What it holds | Source |
| --- | --- | --- |
| `stars.bin` | Every star to magnitude 6 (position, magnitude, B-V color), brightest first | d3-celestial `stars.6.json` (Hipparcos) |
| `sky.json` | Constellation figures and names, star names, deep-sky objects | d3-celestial `constellations*.json`, `starnames.json`, `messier.json`, `dsos.bright.json` |
| `milky_way.jpg` | The Milky Way without its bright stars, 2048x1024, tone mapped | NASA SVS Deep Star Maps 2020, `milkyway_2020_4k.exr` |
| `moon.jpg` | The Moon's near side as a 512 pixel disk | NASA SVS CGI Moon Kit, `lroc_color_2k.jpg` |

## Credits

Milky Way: NASA/Goddard Space Flight Center Scientific Visualization Studio,
https://svs.gsfc.nasa.gov/4851. Gaia DR2: ESA/Gaia/DPAC.

Moon: NASA's Scientific Visualization Studio, CGI Moon Kit,
https://svs.gsfc.nasa.gov/4720. Imagery from the Lunar Reconnaissance Orbiter
Camera (LROC), NASA/GSFC/Arizona State University.

NASA imagery is not protected by copyright in the United States and may be
used freely.

## d3-celestial license

https://github.com/ofrohn/d3-celestial

Copyright (c) 2015, Olaf Frohn
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
