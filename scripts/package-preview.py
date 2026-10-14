#!/usr/bin/env python3
"""Package the existing Debug build with a stable local signing identity.

Usage: python3 scripts/package-preview.py --identity 'V2Do Dev'
Produces build/preview-staged/Pinny.app; installation is separate.
Never falls back to ad-hoc signing or modifies the keychain / TCC database.
"""
import argparse
from datetime import datetime
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--identity', required=True, help='Existing macOS code-signing identity name or SHA-1')
args = parser.parse_args()
if args.identity == '-':
    parser.error('A stable signing identity is required; ad-hoc signing invalidates TCC after updates.')
workspace = Path(__file__).resolve().parents[2]
source = workspace / 'build/in-place-pin/Build/Products/Debug/Snapzy Debug.app'
destination = workspace / 'build/preview-staged/Pinny.app'
if not (source / 'Contents/MacOS/Snapzy').is_file():
    parser.error('Build the Snapzy Debug scheme in build/in-place-pin before packaging.')
if destination.exists():
    backup = destination.with_name('Pinny.' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.app.bak')
    shutil.move(destination, backup)
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', str(source), str(destination)], check=True)
info_path = destination / 'Contents/Info.plist'
with info_path.open('rb') as stream:
    info = plistlib.load(stream)
info.update(CFBundleIdentifier='com.tianruian.openshot.preview',
            CFBundleName='Pinny', CFBundleDisplayName='Pinny')
# Personal build: never fetch the upstream Snapzy appcast, which would replace
# this build with the original app.
info.pop('SUFeedURL', None)
info.update(SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False, SUAutomaticallyUpdate=False)
with info_path.open('wb') as stream:
    plistlib.dump(info, stream)
subprocess.run(['codesign', '--force', '--sign', args.identity, '--timestamp=none',
                '--identifier', info['CFBundleIdentifier'], str(destination)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
subprocess.run(['codesign', '-d', '-r-', str(destination)], check=True)
print(destination)
