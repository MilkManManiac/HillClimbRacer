#!/usr/bin/env bash
## Verification battery — one command, exits nonzero if ANY probe fails.
## Usage: bash tests/run_battery.sh            (from the repo root)
##        GODOT=/path/to/godot bash tests/run_battery.sh
## Works on macOS/Linux natively and on Windows via Git Bash.
set -u
cd "$(dirname "$0")/.."

find_godot() {
	if [ -n "${GODOT:-}" ]; then echo "$GODOT"; return; fi
	local candidates=(
		"$HOME/Tools/Godot/Godot.app/Contents/MacOS/Godot"
		"/c/Users/weshu/Tools/Godot/Godot_v4.6.3-stable_win64_console.exe"
		"$(command -v godot || true)"
		"$(command -v godot4 || true)"
	)
	for c in "${candidates[@]}"; do
		[ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
	done
}

GODOT_BIN="$(find_godot)"
if [ -z "$GODOT_BIN" ]; then
	echo "run_battery: no Godot binary found — set GODOT=/path/to/godot" >&2
	exit 2
fi

PROBES=(SmoothProbe HCDrive MapProbe TitleFlowProbe CarBodyProbe)
fails=0
for p in "${PROBES[@]}"; do
	out="$("$GODOT_BIN" --headless --path . "tests/$p.tscn" 2>&1)"
	code=$?
	if [ $code -eq 0 ]; then
		echo "PASS  $p"
	else
		fails=$((fails + 1))
		echo "FAIL  $p (exit $code)"
		echo "$out" | tail -20 | sed 's/^/      /'
	fi
done

[ $fails -eq 0 ] && echo "battery: ALL GREEN" || echo "battery: $fails FAILED"
exit $((fails > 0))
