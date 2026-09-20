#!/bin/bash
# Captures a screenshot into the run's numbered screenshot sequence and
# refuses anything that could not have shown a real screen: a capture under
# a byte-size floor, or one so uniform it carries essentially no picture
# information (KTD2 — "A capture below a byte-size floor or with near-zero
# variance is a harness error, not evidence.").
#
# Usage:
#   shot.sh --dir <dir> --label <label> [--min-bytes N] [--min-ratio R]
#
# Captures with `screencapture -x` (no shutter sound; invoked by bare name
# so a test can put a stub ahead of it on PATH) into
# <dir>/NNN-<label>.png, where NNN is the next free zero-padded 3-digit
# index *local to <dir>* (each scenario's own screenshots directory starts
# at 001). Prints the resulting path on stdout.
#
# There is no literal "histogram" property in `sips` to call — it reports
# dimensions, sample count and bit depth, not per-pixel statistics — so the
# variance check compares the file's actual, PNG-compressed byte size
# against the fully uncompressed size those properties imply. A screen with
# real content (menu bars, text, icons) compresses far less than a blank or
# single-colour one. UNCALIBRATED: --min-ratio's default below was set from
# synthetic single-colour PNGs at plausible capture sizes, measured by hand
# (200x200 ratio 0.0036 down to 2560x1600 ratio 0.0012), not from a real
# screenshot off the golden image, which does not exist yet. Confirm it
# against a real captured desktop on first boot and adjust if a legitimate
# screenshot ever compresses this well (a nearly all-white Settings pane
# might); until then this is a coarse floor, not a tuned threshold.
#
# Exit codes: 0 the file is on disk and passed both checks, 2 usage error,
# 3 the capture is missing, undersized, or near-zero variance.
set -euo pipefail

DIR=""
LABEL=""
MIN_BYTES=5000
VARIANCE_RATIO_FLOOR="0.01"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --min-bytes) MIN_BYTES="$2"; shift 2 ;;
    --min-ratio) VARIANCE_RATIO_FLOOR="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DIR" ] || [ -z "$LABEL" ]; then
  echo "error: --dir and --label are required." >&2
  exit 2
fi
case "$MIN_BYTES" in ''|*[!0-9]*) echo "error: --min-bytes must be a non-negative integer." >&2; exit 2 ;; esac

mkdir -p "$DIR"

# Next free zero-padded 3-digit index, local to this directory.
next=1
for existing in "$DIR"/[0-9][0-9][0-9]-*.png; do
  [ -e "$existing" ] || continue
  base="$(basename "$existing")"
  n="${base%%-*}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  n=$((10#$n))
  if [ "$n" -ge "$next" ]; then
    next=$((n + 1))
  fi
done
printf -v idx '%03d' "$next"
OUT="$DIR/${idx}-${LABEL}.png"

screencapture -x "$OUT"

if [ ! -s "$OUT" ]; then
  echo "error: screenshot at $OUT is missing or zero bytes." >&2
  exit 3
fi

SIZE=$(wc -c < "$OUT" | tr -d ' ')
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
  echo "error: screenshot at $OUT is $SIZE bytes, under the $MIN_BYTES-byte floor." >&2
  exit 3
fi

# Best-effort: a sips failure (unreadable image, unexpected format) is
# reported as its own harness error rather than silently waved through as
# "no variance data, must be fine".
PROPS="$(sips -g pixelWidth -g pixelHeight -g samplesPerPixel -g bitsPerSample "$OUT" 2>/dev/null || true)"
WIDTH="$(printf '%s\n' "$PROPS" | awk '/pixelWidth:/ {print $2}')"
HEIGHT="$(printf '%s\n' "$PROPS" | awk '/pixelHeight:/ {print $2}')"
SAMPLES="$(printf '%s\n' "$PROPS" | awk '/samplesPerPixel:/ {print $2}')"
BITS="$(printf '%s\n' "$PROPS" | awk '/bitsPerSample:/ {print $2}')"

if [ -z "$WIDTH" ] || [ -z "$HEIGHT" ] || [ -z "$SAMPLES" ] || [ -z "$BITS" ]; then
  echo "error: sips could not read image properties from $OUT." >&2
  exit 3
fi

RATIO="$(awk -v w="$WIDTH" -v h="$HEIGHT" -v s="$SAMPLES" -v b="$BITS" -v actual="$SIZE" \
  'BEGIN { raw = w * h * s * (b / 8); if (raw <= 0) { print "1"; exit } printf "%.8f", actual / raw }')"
BELOW="$(awk -v r="$RATIO" -v floor="$VARIANCE_RATIO_FLOOR" 'BEGIN { print (r < floor) ? "1" : "0" }')"
if [ "$BELOW" = "1" ]; then
  echo "error: screenshot at $OUT has near-zero variance (compressed/raw ratio $RATIO, floor $VARIANCE_RATIO_FLOOR)." >&2
  exit 3
fi

echo "$OUT"
