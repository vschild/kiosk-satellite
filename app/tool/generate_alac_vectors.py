"""Builds the AirPlay receiver's ALAC test vectors: a deterministic stereo
signal, encoded by ffmpeg, for AlacDecoderTest.

The signal is integer-only so the Kotlin test can rebuild it exactly.
Writes <out>: b'ALAC' + u32 count + (u32 size + bytes) per packet.

    python3 tool/generate_alac_vectors.py \\
        android/app/src/test/resources/airplay/alac_default.bin
    python3 tool/generate_alac_vectors.py \\
        android/app/src/test/resources/airplay/alac_order30.bin \\
        -min_prediction_order 1 -max_prediction_order 30
"""
import json, struct, subprocess, sys, os

FRAMES = 17640

def tri(n, period, amp):
    p = n % period
    half = period // 2
    v = p if p < half else period - p
    return (v * 2 * amp) // half - amp

def clamp(v):
    return max(-32768, min(32767, v))

def signal():
    seed = 12345
    out = []
    for n in range(FRAMES):
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        noise = (seed >> 16) % 2001 - 1000
        if n < 8820:
            l = tri(n, 100, 9000) + noise // 4
            r = tri(n, 77, 7000) - noise // 8 + l // 3
        elif n < 13230:
            l = 0
            r = 0
        else:
            l = noise * 30
            r = -l + noise
        out.append((clamp(l), clamp(r)))
    return out

def main(out, *extra):
    raw = b''.join(struct.pack('<hh', l, r) for l, r in signal())
    tmp = out + '.m4a'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 's16le', '-ar', '44100', '-ac', '2',
                    '-i', '-', '-c:a', 'alac', *extra, tmp], input=raw, check=True)
    probe = subprocess.run(['ffprobe', '-hide_banner', '-loglevel', 'error', '-select_streams', 'a', '-show_packets',
                            '-show_data', '-of', 'json', tmp], capture_output=True, check=True)
    packets = []
    for p in json.loads(probe.stdout)['packets']:
        data = bytearray()
        for line in p['data'].strip().split('\n'):
            hexpart = line.split(':', 1)[1][:40]
            data += bytes.fromhex(hexpart.replace(' ', ''))
        assert len(data) == int(p['size']), (len(data), p['size'])
        packets.append(bytes(data))
    with open(out, 'wb') as f:
        f.write(b'ALAC' + struct.pack('>I', len(packets)))
        for p in packets:
            f.write(struct.pack('>I', len(p)) + p)
    # Cross-check: ffmpeg's own decode is the source, bit for bit.
    dec = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', tmp, '-f', 's16le', '-'],
                         capture_output=True, check=True).stdout
    assert dec == raw, 'ffmpeg round trip differs'
    os.remove(tmp)
    print(out, len(packets), 'packets', sum(len(p) for p in packets), 'bytes')

if __name__ == '__main__':
    main(sys.argv[1], *sys.argv[2:])
