#!/bin/bash
# Rebuilds MystNotes/ExcalidrawWeb/excalidraw.bundle.js and excalidraw.css from
# entry.jsx. Run this after editing entry.jsx, or after bumping the
# @excalidraw/excalidraw version in package.json.
#
# This folder is intentionally OUTSIDE MystNotes/ (the Xcode synchronized
# source root) so npm/node_modules/build tooling never gets bundled into the
# app target - only the two output files it produces do.
set -euo pipefail
cd "$(dirname "$0")"

npm install
npx esbuild entry.jsx --bundle --minify --format=iife --outfile=../MystNotes/ExcalidrawWeb/excalidraw.bundle.js
cp node_modules/@excalidraw/excalidraw/dist/prod/index.css ../MystNotes/ExcalidrawWeb/excalidraw.css

# @excalidraw/excalidraw ships its own public Firebase client config (their
# hosted live-collaboration/room-persistence backend) baked into its dist
# chunk as a plain string literal. We never call any of their collaboration
# APIs, so it's dead code here - but it still trips secret scanners as a
# bare "AIza..." key, so strip it out of our vendored copy. (Blanking the
# apiKey alone is enough; the surrounding fields aren't secret at all.)
node -e '
const fs = require("fs");
const path = "../MystNotes/ExcalidrawWeb/excalidraw.bundle.js";
const before = fs.readFileSync(path, "utf8");
const after = before.replace(/"apiKey":"AIza[A-Za-z0-9_-]{35}"/, "\"apiKey\":\"\"");
if (after === before) {
  console.log("Note: no embedded Firebase apiKey found to strip (excalidraw version may have changed this).");
} else {
  fs.writeFileSync(path, after);
  console.log("Stripped vendored Firebase apiKey from excalidraw.bundle.js");
}
'

echo "Rebuilt MystNotes/ExcalidrawWeb/excalidraw.bundle.js and excalidraw.css"
