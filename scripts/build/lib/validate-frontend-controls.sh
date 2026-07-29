#!/bin/sh
#
# NebulaOS mainline print-controls mission (2026-07-29, see
# docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md). Shared by
# scripts/build/04-cross-compile-app-stack.sh (real build, validates the
# tracked overlay source) and tests/nebulaos-frontend-controls-validation-
# tests.sh (offline fixture configs) - kept in its own file specifically
# so the tests exercise this exact function, not a second/parallel
# reimplementation of its validation rules (same convention as
# scripts/build/lib/make-seed-archive.sh).
#
# Every function here prints its own OK/FATAL lines and returns 0/1 - none
# of them call exit, so callers (a real build script, or a test harness
# that wants to keep going after a failure) decide what a failure means.
#
# Resolves every [include ...] starting from a given config file, relative
# to a config source directory, into a single flat file - this project's
# configs only ever use plain literal filenames in includes (one level of
# GuppyScreen/ nesting), never glob patterns, so this is a deliberately
# simple closure builder, not a general Klipper config parser.
#
# Usage: frontend_controls_resolve_closure <config_src_dir> <entry_file> <closure_out_file>
frontend_controls_resolve_closure() {
	fc_src="$1"
	fc_entry="$2"
	fc_out="$3"
	: > "$fc_out"
	_frontend_controls_resolve_one "$fc_src" "$fc_entry" "$fc_out"
}

_frontend_controls_resolve_one() {
	rc_src="$1"
	rc_rel="$2"
	rc_out="$3"
	rc_f="$rc_src/$rc_rel"
	if [ ! -f "$rc_f" ]; then
		echo "FATAL: $rc_rel is referenced (directly or via include) but does not exist under $rc_src" >&2
		return 1
	fi
	cat "$rc_f" >> "$rc_out"
	rc_dirname=$(dirname "$rc_rel")
	rc_status=0
	grep -o "^\[include [^]]*\]" "$rc_f" 2>/dev/null | sed -e "s/^\[include[[:space:]]*//" -e "s/[[:space:]]*\]\$//" | while read -r rc_inc; do
		if [ "$rc_dirname" = "." ]; then
			rc_inc_rel="$rc_inc"
		else
			rc_inc_rel="$rc_dirname/$rc_inc"
		fi
		_frontend_controls_resolve_one "$rc_src" "$rc_inc_rel" "$rc_out" || exit 1
	done || rc_status=1
	return "$rc_status"
}

# Counts occurrences (case-insensitive) of an extended-regex section-header
# pattern in a resolved closure file, and enforces [min, max] inclusive.
# Usage: frontend_controls_check_count <label> <pattern> <min> <max> <closure_file>
frontend_controls_check_count() {
	cc_label="$1"
	cc_pattern="$2"
	cc_min="$3"
	cc_max="$4"
	cc_file="$5"
	cc_count=$(grep -c -i -E "$cc_pattern" "$cc_file")
	if [ "$cc_count" -lt "$cc_min" ]; then
		echo "FATAL: print-control config closure is missing $cc_label (found $cc_count, need at least $cc_min)" >&2
		return 1
	fi
	if [ "$cc_count" -gt "$cc_max" ]; then
		echo "FATAL: print-control config closure has $cc_count definitions of $cc_label (max $cc_max allowed)" >&2
		return 1
	fi
	return 0
}

# Detects a [gcode_macro X] section whose rename_existing value is X itself
# (case-insensitive) - a self-referential override Klipper would either
# reject or silently misbehave on.
# Usage: frontend_controls_check_circular_rename <closure_file>
frontend_controls_check_circular_rename() {
	cr_file="$1"
	cr_hits=$(awk '
		BEGIN { IGNORECASE = 1 }
		/^\[[[:space:]]*gcode_macro[[:space:]]+/ {
			name = $0
			sub(/^\[[[:space:]]*gcode_macro[[:space:]]+/, "", name)
			sub(/[[:space:]]*\]$/, "", name)
			cur = name
			next
		}
		/^\[/ { cur = "" }
		cur != "" && /^[[:space:]]*rename_existing[[:space:]]*:/ {
			val = $0
			sub(/^[[:space:]]*rename_existing[[:space:]]*:[[:space:]]*/, "", val)
			gsub(/[[:space:]]+$/, "", val)
			if (tolower(val) == tolower(cur)) {
				print cur
			}
		}
	' "$cr_file")
	if [ -n "$cr_hits" ]; then
		echo "FATAL: print-control config closure has a recursive rename_existing chain (a [gcode_macro X] renaming itself to X): $cr_hits" >&2
		return 1
	fi
	return 0
}

# Extracts [virtual_sdcard]'s path option value from a resolved closure
# file (empty string if the section or option is absent).
# Usage: frontend_controls_vsd_path <closure_file>
frontend_controls_vsd_path() {
	awk '
		/^\[[[:space:]]*virtual_sdcard[[:space:]]*\]/ { in_vsd = 1; next }
		/^\[/ { in_vsd = 0 }
		in_vsd && /^[[:space:]]*path[[:space:]]*:/ {
			sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "")
			gsub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$1"
}

# Runs the full standard set of checks (all six named objects/commands,
# plus the circular-rename guard and the canonical gcode path) against an
# already-resolved closure file. Prints one line per check, returns 0 only
# if every check passed.
# Usage: frontend_controls_validate_closure <closure_file> <expected_gcode_path>
frontend_controls_validate_closure() {
	vc_file="$1"
	vc_expected_path="$2"
	vc_ok=0

	frontend_controls_check_count "[virtual_sdcard]" "^\[[[:space:]]*virtual_sdcard[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[pause_resume]" "^\[[[:space:]]*pause_resume[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[display_status]" "^\[[[:space:]]*display_status[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[gcode_macro PAUSE]" "^\[[[:space:]]*gcode_macro[[:space:]]+pause[[:space:]]*\]" 0 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[gcode_macro RESUME]" "^\[[[:space:]]*gcode_macro[[:space:]]+resume[[:space:]]*\]" 0 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[gcode_macro CANCEL_PRINT]" "^\[[[:space:]]*gcode_macro[[:space:]]+cancel_print[[:space:]]*\]" 0 1 "$vc_file" || vc_ok=1
	frontend_controls_check_circular_rename "$vc_file" || vc_ok=1

	vc_path=$(frontend_controls_vsd_path "$vc_file")
	if [ "$vc_path" != "$vc_expected_path" ]; then
		echo "FATAL: [virtual_sdcard] path is $vc_path, expected $vc_expected_path" >&2
		vc_ok=1
	fi

	return "$vc_ok"
}
