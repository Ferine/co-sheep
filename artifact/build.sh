#!/usr/bin/env bash
# Builds co-sheep.html: the legacy TypeScript flock (from git history,
# the last commit before the Swift swap) + the artifact shell in src/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
legacy_rev="8e7b2db^"   # "Swap: remove the Tauri/TypeScript/Rust app" — its parent

build="$here/.build"
rm -rf "$build/legacy"
mkdir -p "$build/legacy"
git -C "$repo" archive "$legacy_rev" src | tar -x -C "$build/legacy"
rm -f "$build"/legacy/src/*.test.ts "$build/legacy/src/main.ts" "$build/legacy/src/styles.css"
python3 "$here/patch.py" "$build/legacy/src" "$repo/Sources/CoSheepKit/Resources/sprites"

if [ ! -x "$build/node_modules/.bin/esbuild" ]; then
  (cd "$build" && printf '{"name":"co-sheep-artifact-build","private":true}\n' > package.json && npm install --silent esbuild@0.24.2)
fi

"$build/node_modules/.bin/esbuild" "$here/src/main.ts" \
  --bundle --format=iife --target=es2022 --minify --legal-comments=none \
  --alias:legacy="$build/legacy/src" \
  --alias:@tauri-apps/api/core="$here/src/tauri-core.ts" \
  --alias:@tauri-apps/api/event="$here/src/tauri-event.ts" \
  --outfile="$build/bundle.js"

python3 - "$here/src/template.html" "$build/bundle.js" "$here/co-sheep.html" <<'PY'
import sys, pathlib
template, bundle, out = (pathlib.Path(p) for p in sys.argv[1:])
js = bundle.read_text().replace("</script", "<\\/script")
html = template.read_text()
assert html.count("/*BUNDLE*/") == 1
pathlib.Path(out).write_text(html.replace("/*BUNDLE*/", js))
print(f"wrote {out} ({out.stat().st_size // 1024} KB)")
PY
