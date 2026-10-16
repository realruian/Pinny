#!/usr/bin/env bash
set -euo pipefail

# Build, sign, back up, and install Pinny.app to /Applications/Pinny.app.
# Usage:
#   ./scripts/install-pinny.sh [--identity "V2Do Dev"] [--skip-build] [--no-open]

IDENTITY="V2Do Dev"
SKIP_BUILD=false
OPEN_APP=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --no-open)
      OPEN_APP=false
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--identity <signing-identity>] [--skip-build] [--no-open]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "Error: A stable code-signing identity is required to preserve macOS TCC permissions." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$REPO_ROOT/.." && pwd)"
cd "$REPO_ROOT"

if [[ "$SKIP_BUILD" == false ]]; then
  echo "==> Building Pinny (Release, arm64)..."
  xcodebuild -project Snapzy.xcodeproj \
    -scheme Snapzy \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$WORKSPACE_DIR/build/release" \
    -clonedSourcePackagesDirPath "$WORKSPACE_DIR/build/packages" \
    -disableAutomaticPackageResolution \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    ONLY_ACTIVE_ARCH=YES \
    build
fi

echo "==> Packaging and signing Pinny.app with identity '$IDENTITY'..."
python3 scripts/package-preview.py --identity "$IDENTITY" --configuration Release

STAGED_APP="$WORKSPACE_DIR/build/preview-staged/Pinny.app"
TARGET_APP="/Applications/Pinny.app"
BACKUP_DIR="$WORKSPACE_DIR/build/preview"
BACKUP_APP="$BACKUP_DIR/Pinny.before-update.$(date +%Y%m%d).app.bak"

echo "==> Stopping running Pinny instance (if any)..."
osascript -e 'tell application id "com.tianruian.openshot.preview" to quit' >/dev/null 2>&1 || true

if [[ -d "$TARGET_APP" ]]; then
  mkdir -p "$BACKUP_DIR"
  rm -rf "$BACKUP_APP"
  echo "==> Backing up existing $TARGET_APP to $BACKUP_APP..."
  ditto "$TARGET_APP" "$BACKUP_APP"
fi

echo "==> Installing $TARGET_APP..."
rm -rf "$TARGET_APP"
ditto "$STAGED_APP" "$TARGET_APP"

if [[ "$OPEN_APP" == true ]]; then
  echo "==> Launching Pinny..."
  open "$TARGET_APP"
fi

echo "==> Done: $TARGET_APP"
