"""Validate generated app metadata, not merely the source build settings."""
import plistlib
import sys
from pathlib import Path
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
assert info.get('CADisableMinimumFrameDurationOnPhone') is True, 'ProMotion opt-in missing from built app'
assert info.get('MinimumOSVersion') == '18.0'
print('Built iOS app metadata passed')
