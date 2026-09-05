#!/bin/bash
#
# Regenerates icon/Vigil.iconset/*.png from icon/vigil-icon.svg.
#
# Only needed if you edit the SVG. The PNGs are committed, so a normal build
# just runs `iconutil` over them (see the `icon` target in the Makefile) and
# needs nothing beyond stock macOS.
#
# macOS ships no SVG rasteriser usable from the command line, so this needs
# one of:
#     brew install librsvg          # rsvg-convert
#     pip install cairosvg
#
# Each size is rendered from the vector at its true size rather than
# downsampled from 1024, which keeps the 16 and 32px versions crisp.

set -euo pipefail

cd "$(dirname "$0")/.."

SVG="icon/vigil-icon.svg"
SET="icon/Vigil.iconset"

test -f "$SVG" || { echo "Missing $SVG"; exit 1; }
mkdir -p "$SET"

if command -v rsvg-convert >/dev/null 2>&1; then
    render() { rsvg-convert -w "$2" -h "$2" "$SVG" -o "$SET/$1"; }
elif python3 -c "import cairosvg" >/dev/null 2>&1; then
    render() {
        python3 -c "
import cairosvg, sys
cairosvg.svg2png(url='$SVG', write_to='$SET/$1',
                 output_width=$2, output_height=$2)"
    }
else
    echo "No SVG rasteriser found. Install one:"
    echo "  brew install librsvg     (rsvg-convert)"
    echo "  pip install cairosvg"
    exit 1
fi

while read -r name size; do
    render "$name" "$size"
    echo "  $name ($size)"
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

echo
echo "Now run: make icon"
