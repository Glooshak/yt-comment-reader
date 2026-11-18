#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/CommentReader.app"
CONTENTS="$APP/Contents"

echo "Building Comment Reader…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -parse-as-library -O -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -framework SwiftUI -framework AppKit \
    "$ROOT/app/main.swift" "$ROOT/app/YouTubeFetcher.swift" \
    -o "$CONTENTS/MacOS/CommentReader"

cp "$ROOT/app/Info.plist" "$CONTENTS/Info.plist"

if [ -f "$ROOT/data/corpus.json" ]; then
    cp "$ROOT/data/corpus.json" "$CONTENTS/Resources/corpus.json"
    echo "Embedded corpus: $(du -h "$ROOT/data/corpus.json" | cut -f1)"
else
    echo "WARNING: data/corpus.json missing — the app will ask for one."
fi

if [ -f "$ROOT/app/AppIcon.icns" ]; then
    cp "$ROOT/app/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
