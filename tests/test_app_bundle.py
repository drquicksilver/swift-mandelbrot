"""Validate generated app metadata, not merely the source build settings."""
import plistlib
import sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
assert info.get('CADisableMinimumFrameDurationOnPhone') is True, 'ProMotion opt-in missing from built app'
assert info.get('MinimumOSVersion') == '18.0'
schemes = [s for t in info.get('CFBundleURLTypes', []) for s in t.get('CFBundleURLSchemes', [])]
assert 'mandelbrot' in schemes, 'Location URL scheme missing from built app'
notice = Path(sys.argv[1]).parent/'LICENSE.md'
source = Path(__file__).resolve().parents[1]/'Mandelbrot/Core/Vendor/BigInt/LICENSE.md'
assert notice.read_bytes() == source.read_bytes(), 'BigInt MIT notice missing or altered in built app'
print('Built iOS app metadata and bundled MIT notice passed')
