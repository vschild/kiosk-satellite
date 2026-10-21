#!/usr/bin/env python3
"""Builds the Celestial screensaver's bundled sky data in assets/celestial.

Downloads the sources into a cache folder, then writes:

  stars.bin       every star to magnitude 6 from d3-celestial, brightest first
  sky.json        constellation figures (ra, dec, star magnitude per vertex) and
                  names, star names, deep-sky objects
  milky_way.jpg   NASA's Deep Star Maps 2020 Milky Way, tone mapped to 2048x1024
  moon.jpg        the Moon's near side from NASA's CGI Moon Kit, as a 512 disk

Needs numpy, Pillow and ImageMagick (for the OpenEXR source). Run from app/:

  python3 tool/generate_celestial_assets.py --cache /tmp/celestial-cache
"""

import argparse
import json
import math
import os
import struct
import subprocess
import urllib.request

import numpy as np
from PIL import Image

D3 = 'https://raw.githubusercontent.com/ofrohn/d3-celestial/master/data/'
SVS_STARS = 'https://svs.gsfc.nasa.gov/vis/a000000/a004800/a004851/'
SVS_MOON = 'https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/'

SOURCES = {
    'stars.6.json': D3 + 'stars.6.json',
    'starnames.json': D3 + 'starnames.json',
    'constellations.json': D3 + 'constellations.json',
    'constellations.lines.json': D3 + 'constellations.lines.json',
    'messier.json': D3 + 'messier.json',
    'dsos.bright.json': D3 + 'dsos.bright.json',
    'milkyway_2020_4k.exr': SVS_STARS + 'milkyway_2020_4k.exr',
    'lroc_color_2k.jpg': SVS_MOON + 'lroc_color_2k.jpg',
}

# Constellation name languages d3-celestial carries that the app ships.
NAME_LANGUAGES = ['es', 'de', 'fr', 'ru', 'zh']

# Superscript digits for Bayer letters shared by close stars, like κ¹.
SUPERSCRIPT = str.maketrans('0123456789', '⁰¹²³⁴⁵⁶⁷⁸⁹')

# Deep-sky objects worth a label at naked-eye scale: (catalog id in the
# d3 files, message key, kind, position angle of the major axis in
# degrees east of north). Kinds: galaxy and nebula draw a soft glow,
# cluster only a label. The Magellanic Clouds are in the Milky Way image.
DSOS = [
    ('M31', 'andromedaGalaxy', 'galaxy', 35),
    ('NGC 598', 'triangulumGalaxy', 'galaxy', 23),
    ('PGC 17223', 'largeMagellanicCloud', 'cloud', 0),
    ('NGC 292', 'smallMagellanicCloud', 'cloud', 0),
    ('M42', 'orionNebula', 'nebula', 0),
    ('M 8', 'lagoonNebula', 'nebula', 90),
    ('NGC 3372', 'carinaNebula', 'nebula', 0),
    ('M45', 'pleiades', 'cluster', 0),
    ('M44', 'beehiveCluster', 'cluster', 0),
    ('NGC 869', 'doubleCluster', 'cluster', 0),
    ('NGC 5139', 'omegaCentauri', 'cluster', 0),
    ('NGC 104', 'tucanae47', 'cluster', 0),
]


def fetch(cache, name):
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        print('downloading', SOURCES[name])
        urllib.request.urlretrieve(SOURCES[name], path + '.part')
        os.replace(path + '.part', path)
    return path


def load(cache, name):
    with open(fetch(cache, name), encoding='utf-8') as f:
        return json.load(f)


def ra360(value):
    return round(value % 360.0, 4)


def build_stars(cache, out):
    stars = load(cache, 'stars.6.json')['features']
    names = load(cache, 'starnames.json')
    rows = []
    for feature in stars:
        mag = feature['properties']['mag']
        try:
            bv = float(feature['properties'].get('bv') or 0.6)
        except ValueError:
            bv = 0.6
        ra, dec = feature['geometry']['coordinates']
        entry = names.get(str(feature['id']), {})
        rows.append((mag, ra % 360.0, dec, bv, entry))
    rows.sort(key=lambda r: r[0])
    data = bytearray(b'KSS1')
    data += struct.pack('<I', len(rows))
    named, designated = {}, {}
    for index, (mag, ra, dec, bv, entry) in enumerate(rows):
        data += struct.pack(
            '<ffhh',
            ra,
            dec,
            round(mag * 100),
            round(max(-0.4, min(2.0, bv)) * 1000),
        )
        # Every proper name, and for the rest the Bayer letter or the
        # Flamsteed number with the constellation, like γ Cen or 61 Cyg.
        # The renderer decides how many to show from the field of view.
        name = entry.get('name', '')
        bayer = entry.get('bayer', '').translate(SUPERSCRIPT)
        flam = entry.get('flam', '')
        if name:
            named[str(index)] = name
        elif bayer or flam:
            designated[str(index)] = f"{bayer or flam} {entry['c']}"
    with open(os.path.join(out, 'stars.bin'), 'wb') as f:
        f.write(data)
    print('stars', len(rows), 'named', len(named), 'designated', len(designated))
    return named, designated


def vertex_magnitudes(cache):
    """The magnitude of the catalog star at each figure vertex, so the
    renderer only leaves a gap in a line where its star is visible."""
    stars = load(cache, 'stars.6.json')['features']
    xyz = np.array([
        [math.cos(math.radians(d)) * math.cos(math.radians(r)),
         math.cos(math.radians(d)) * math.sin(math.radians(r)),
         math.sin(math.radians(d))]
        for r, d in (f['geometry']['coordinates'] for f in stars)
    ])
    mags = np.array([f['properties']['mag'] for f in stars])
    limit = math.cos(math.radians(0.1))

    def magnitude(lon, lat):
        v = np.array([
            math.cos(math.radians(lat)) * math.cos(math.radians(lon)),
            math.cos(math.radians(lat)) * math.sin(math.radians(lon)),
            math.sin(math.radians(lat)),
        ])
        dots = xyz @ v
        best = int(np.argmax(dots))
        return round(float(mags[best]), 2) if dots[best] > limit else 9.0
    return magnitude


def build_sky(cache, out, star_names, star_designations):
    info = {f['id']: f for f in load(cache, 'constellations.json')['features']}
    magnitude = vertex_magnitudes(cache)
    constellations = []
    for feature in load(cache, 'constellations.lines.json')['features']:
        cid = feature['id']
        props = info[cid]['properties']
        ra, dec = info[cid]['geometry']['coordinates']
        lines = []
        for line in feature['geometry']['coordinates']:
            flat = []
            for lon, lat in line:
                flat += [ra360(lon), round(lat, 4), magnitude(lon, lat)]
            lines.append(flat)
        constellations.append({
            'id': cid,
            'name': props['name'],
            'names': {lang: props[lang] for lang in NAME_LANGUAGES if props.get(lang)},
            'rank': int(props.get('rank', 3)),
            'ra': ra360(ra),
            'dec': round(dec, 4),
            'lines': lines,
        })
    catalog = {}
    for name in ('messier.json', 'dsos.bright.json'):
        for feature in load(cache, name)['features']:
            catalog.setdefault(feature['id'], feature)
    dsos = []
    for cid, key, kind, pa in DSOS:
        feature = catalog[cid]
        ra, dec = feature['geometry']['coordinates']
        dim = str(feature['properties'].get('dim') or '10')
        size = [float(v) for v in dim.split('x')]
        if len(size) == 1:
            size.append(size[0])
        dsos.append({
            'key': key,
            'kind': kind,
            'ra': ra360(ra),
            'dec': round(dec, 4),
            'mag': feature['properties']['mag'],
            'size': size,
            'pa': pa,
        })
    sky = {
        'constellations': constellations,
        'starNames': star_names,
        'starDesignations': star_designations,
        'dsos': dsos,
    }
    with open(os.path.join(out, 'sky.json'), 'w', encoding='utf-8') as f:
        json.dump(sky, f, ensure_ascii=False, separators=(',', ':'))
    print('constellations', len(constellations), 'dsos', len(dsos))


def read_pfm(path):
    with open(path, 'rb') as f:
        assert f.readline().strip() == b'PF'
        width, height = map(int, f.readline().split())
        scale = float(f.readline())
        data = np.frombuffer(f.read(), dtype='<f4' if scale < 0 else '>f4')
    return data.reshape(height, width, 3)[::-1].astype(np.float64)


def build_milky_way(cache, out):
    """RA runs right to left with 0h in the middle, as NASA publishes it.

    The asinh stretch keeps the faint background near black and the
    galactic core short of white. Color is pulled toward gray, since the
    source's reddening reads as orange at this exposure.
    """
    pfm = os.path.join(cache, 'milkyway_2020_4k.pfm')
    if not os.path.exists(pfm):
        subprocess.run([
            'magick', fetch(cache, 'milkyway_2020_4k.exr'),
            '-colorspace', 'RGB', '-set', 'colorspace', 'RGB',
            '-define', 'quantum:format=floating-point', '-depth', '32', pfm,
        ], check=True)
    linear = read_pfm(pfm)
    linear = linear.reshape(1024, 2, 2048, 2, 3).mean(axis=(1, 3))
    lum = linear.mean(axis=2, keepdims=True)
    floor, soft = 0.0008, 0.012
    value = np.arcsinh(np.clip(lum - floor, 0, None) / soft)
    value = np.clip(value / math.asinh(0.45 / soft), 0, 1)
    ratio = 1 + (linear / np.maximum(lum, 1e-9) - 1) * 0.42
    rgb = np.clip(value * ratio, 0, 1)
    image = Image.fromarray((rgb * 255 + 0.5).astype(np.uint8))
    image.save(os.path.join(out, 'milky_way.jpg'), quality=85, optimize=True)


def build_moon(cache, out, size=512):
    """Orthographic near side, selenographic north up, east limb on the right
    as the Moon is seen from the northern hemisphere."""
    source = np.asarray(
        Image.open(fetch(cache, 'lroc_color_2k.jpg')).convert('RGB'),
    ).astype(np.float64)
    height, width, _ = source.shape
    # Supersampled, so the limb is antialiased.
    ss = size * 2
    axis = (np.arange(ss) + 0.5) / ss * 2 - 1
    x, y = np.meshgrid(axis, -axis)
    r2 = x * x + y * y
    inside = r2 < 1
    z = np.sqrt(np.clip(1 - r2, 0, 1))
    lon = np.arctan2(x, z)
    lat = np.arcsin(np.clip(y, -1, 1))
    u = ((lon / (2 * math.pi) + 0.5) * width).astype(int) % width
    v = np.clip(((0.5 - lat / math.pi) * height).astype(int), 0, height - 1)
    rgb = source[v, u] * inside[..., None]
    rgb = rgb.reshape(size, 2, size, 2, 3).mean(axis=(1, 3))
    image = Image.fromarray(np.clip(rgb + 0.5, 0, 255).astype(np.uint8))
    image.save(os.path.join(out, 'moon.jpg'), quality=88, optimize=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--cache', required=True, help='download folder')
    parser.add_argument('--out', default='assets/celestial')
    args = parser.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    os.makedirs(args.out, exist_ok=True)
    names, designations = build_stars(args.cache, args.out)
    build_sky(args.cache, args.out, names, designations)
    build_milky_way(args.cache, args.out)
    build_moon(args.cache, args.out)


if __name__ == '__main__':
    main()
