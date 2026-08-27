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

echo "Rebuilt MystNotes/ExcalidrawWeb/excalidraw.bundle.js and excalidraw.css"
