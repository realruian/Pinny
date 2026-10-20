#!/usr/bin/env python3
"""Package the existing Debug build with a stable local signing identity.

Usage: python3 scripts/package-preview.py --identity 'V2Do Dev' [--configuration Release]
Produces build/preview-staged/Pinny.app, replacing the previous staged copy (the
installed app's rollback backup is made at install time); installation is separate.
Never falls back to ad-hoc signing or modifies the keychain / TCC database.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--identity', required=True, help='Existing macOS code-signing identity name or SHA-1')
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug',
                    help='Release is the optimized build in build/release; Debug is build/in-place-pin')
args = parser.parse_args()
if args.identity == '-':
    parser.error('A stable signing identity is required; ad-hoc signing invalidates TCC after updates.')
workspace = Path(__file__).resolve().parents[2]
source = (workspace / 'build/release/Build/Products/Release/Snapzy.app'
          if args.configuration == 'Release'
          else workspace / 'build/in-place-pin/Build/Products/Debug/Snapzy Debug.app')
destination = workspace / 'build/preview-staged/Pinny.app'
if not (source / 'Contents/MacOS/Snapzy').is_file():
    parser.error(f'Build the Snapzy scheme ({args.configuration}) before packaging: {source} is missing.')
if destination.exists():
    # Not kept: extra launchable copies with the same bundle ID confuse Launch Services.
    shutil.rmtree(destination)
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', str(source), str(destination)], check=True)
info_path = destination / 'Contents/Info.plist'
with info_path.open('rb') as stream:
    info = plistlib.load(stream)
# The Xcode target still builds an executable named Snapzy (unit tests load it as their host);
# the installed app shows its executable name in Activity Monitor, crash and memory reports.
executable = info.get('CFBundleExecutable', 'Snapzy')
if executable != 'Pinny':
    (destination / 'Contents/MacOS' / executable).rename(destination / 'Contents/MacOS/Pinny')
info.update(CFBundleIdentifier='com.tianruian.openshot.preview',
            CFBundleName='Pinny', CFBundleDisplayName='Pinny', CFBundleExecutable='Pinny')
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
