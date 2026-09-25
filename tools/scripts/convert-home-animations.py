#!/usr/bin/env python3
"""Losslessly prepare iOS home APNGs from the shipping Android WebPs (macOS).

Usage: python3 tools/scripts/convert-home-animations.py NEW_OUTPUT_DIRECTORY
Requires Xcode's Swift compiler, ImageIO, and Python's standard library. Outputs
are reviewed before copying into app resources. Each decoded frame must match;
this intentionally spends ~20s decoding WebP offline to avoid that runtime cost.
The two APNG files add about 16.15 MiB versus WebP; decoded pixel storage is unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]


def chunks(blob):
    assert blob[:8] == b'\x89PNG\r\n\x1a\n', 'not PNG'
    offset = 8
    while offset < len(blob):
        size = struct.unpack('>I', blob[offset:offset + 4])[0]
        kind = blob[offset + 4:offset + 8]
        payload = blob[offset + 8:offset + 8 + size]
        checksum = struct.unpack('>I', blob[offset + 8 + size:offset + 12 + size])[0]
        assert zlib.crc32(kind + payload) == checksum, 'invalid PNG CRC'
        yield kind, payload
        offset += size + 12
    assert offset == len(blob)


def exact_cadence(original):
    """ImageIO truncates 1/15 to 66/1000; modify timing only, never pixels."""
    result = bytearray(original[:8])
    controls = 0
    for kind, payload in chunks(original):
        if kind == b'fcTL':
            payload = payload[:20] + struct.pack('>HH', 1, 15) + payload[24:]
            controls += 1
        result.extend(struct.pack('>I', len(payload)) + kind + payload)
        result.extend(struct.pack('>I', zlib.crc32(kind + payload)))
    assert controls > 0
    # Verify image/color/compositing payloads remained byte-identical.
    for (kind, before), (after_kind, after) in zip(chunks(original), chunks(result)):
        assert kind == after_kind
        if kind == b'fcTL':
            assert before[:20] + before[24:] == after[:20] + after[24:]
            assert struct.unpack('>HH', after[20:24]) == (1, 15)
        else:
            assert before == after
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    # Reuse the exact runtime-owned RGBA copy without maintaining a second copy.
    runtime = (ROOT / 'apps/ios/Sources/Litter/Views/HomeSessionsScrollView.swift').read_text()
    signature = runtime.index('static func bitmapFrame(from image: CGImage) -> CGImage? {')
    start = runtime.rfind('\n', 0, signature) + 1
    depth = 0
    for end in range(runtime.index('{', start), len(runtime)):
        depth += (runtime[end] == '{') - (runtime[end] == '}')
        if depth == 0:
            break
    method = runtime[start:end + 1]
    with tempfile.TemporaryDirectory(prefix='litter-apng-') as temporary:
        temporary = Path(temporary)
        copy = temporary / 'BitmapCopy.swift'
        copy.write_text('import CoreGraphics\nenum BitmapCopy {\n' + method + '\n}\n')
        executable = temporary / 'encode'
        subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', str(copy),
                        str(ROOT / 'tools/scripts/HomeAnimationEncoder.swift'), '-o', str(executable)], check=True)
        for name in ['home_cat_entrance', 'home_cat']:
            source = ROOT / f'apps/android/app/src/main/res/drawable-nodpi/{name}.webp'
            intermediate = temporary / f'{name}.png'
            report = subprocess.check_output([str(executable), str(source), str(intermediate)], text=True)
            report = json.loads(report)  # Encoder fails unless every frame round-trips.
            candidate = exact_cadence(intermediate.read_bytes())
            output = args.output / f'{name}.png'
            output.write_bytes(candidate)
            report.update(output=str(output), output_sha256=hashlib.sha256(candidate).hexdigest(),
                          bitmap_method_sha256=hashlib.sha256(method.encode()).hexdigest(),
                          encoded_delay_numerator=1, encoded_delay_denominator=15)
            # The pre-normalization roundtrip is still valid: only fcTL clocks
            # and their CRCs changed; all frame/color/compositing bytes match.
            (args.output / f'{name}.json').write_text(json.dumps(report, indent=2) + '\n')
            print(f'{name}: all frames exact; {len(candidate):,} bytes; SHA256 {report["output_sha256"]}')


if __name__ == '__main__':
    main()
