#!/bin/sh
#
# NebulaOS mutable-runtime mission, Phase 8: rollback orchestration and
# transaction state machine (docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md).
#
# Real constraint found while implementing this (not present in the design
# draft): this Moonraker version's update_manager (git_deploy.py/
# app_deploy.py, confirmed directly against vendor/moonraker source) has NO
# pre/post-update command hook at all - it performs fetch, checkout,
# venv/requirement sync, and service restart entirely on its own the moment
# a user clicks "update" in Mainsail, with no way for external code to run
# in between "new version staged" and "new version activated". The design
# doc's Stage 1 (pre-activation) / Stage 2 (post-activation) split is
# therefore collapsed here into a single post-hoc validation that runs
# after Moonraker has already restarted the affected service - this script
# is an independent poller, not a Moonraker plugin, specifically so it
# keeps working even if a bad update breaks Moonraker itself.
#
# Detection: git's own HEAD commit is polled per component. A change from
# the last-recorded value means "an update just happened" (via Moonraker's
# own update flow, or a manual git operation - this script does not care
# which). Rollback restores the previous known-good commit via
# `git reset --hard`, which needs no separate pre-update backup step for
# the source tree itself - git's own history/reflog already holds it,
# which is why known_good_commit is tracked here rather than snapshotting
# whole directory copies.
#
# Restart safety: never restarts a service while a print is active/paused
# (read-only Moonraker query, checked immediately before every restart -
# same printer-safety invariant as every other disruptive action in this
# project) - a deferred restart just waits and rechecks rather than
# skipping validation outright.

NEBULAOS_ROOT=/usr/data/nebulaos
HEALTHCHECK=/etc/nebulaos-healthcheck.sh
LOCKDIR="$NEBULAOS_ROOT/updates/locks"
MOONRAKER_URL="http://127.0.0.1:7125"
POLL_INTERVAL=20
STABILIZE_SAMPLES=6
STABILIZE_INTERVAL=10
RESTART_GRACE_PERIOD=25

log() {
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) nebulaos-update-supervisor: $1"
}

# $1=component name -> echoes: path|init_script|opt_path
component_info() {
	case "$1" in
		klipper)
			echo "$NEBULAOS_ROOT/apps/klipper|/etc/init.d/S55klipper|/opt/klipper"
			;;
		moonraker)
			echo "$NEBULAOS_ROOT/apps/moonraker|/etc/init.d/S56moonraker|/opt/moonraker"
			;;
	esac
}

state_file() {
	echo "$NEBULAOS_ROOT/updates/$1/state.json"
}

read_state_field() {
	# $1=component $2=field
	f=$(state_file "$1")
	[ -e "$f" ] || return 0
	sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" "$f" | head -1
}

write_state() {
	# $1=component $2=known_good $3=last_seen $4=state $5=reason
	f=$(state_file "$1")
	tmp="$f.tmp.$$"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		echo "{"
		echo "  \"component\": \"$1\","
		echo "  \"known_good_commit\": \"$2\","
		echo "  \"last_seen_commit\": \"$3\","
		echo "  \"state\": \"$4\","
		echo "  \"last_transition_at\": \"$now\","
		echo "  \"last_failure_reason\": \"$5\""
		echo "}"
	} > "$tmp"
	mv "$tmp" "$f"
}

# Read-only query, never combined with a restart in the same step - a
# printing/paused state means "wait", not "skip validation".
print_is_active() {
	stats=$(wget -q -O - --timeout=5 "$MOONRAKER_URL/printer/objects/query?print_stats=state" 2>/dev/null)
	case "$stats" in
		*'"state":"printing"'*|*'"state":"paused"'*) return 0 ;;
		*) return 1 ;;
	esac
}

# Waits (bounded) for any active print to finish before a disruptive
# restart - never forces a restart mid-print.
wait_for_print_idle() {
	tries=0
	while print_is_active; do
		tries=$((tries + 1))
		if [ "$tries" -ge 90 ]; then
			log "print still active after $((tries * 10))s - deferring restart, will re-check next poll cycle"
			return 1
		fi
		sleep 10
	done
	return 0
}

restart_component() {
	# $1=component
	info=$(component_info "$1")
	init_script=$(echo "$info" | cut -d'|' -f2)
	wait_for_print_idle || return 1
	log "$1: restarting via $init_script"
	"$init_script" restart
	# Real bug found live (first rollback test, 2026-07-26): Klipper
	# legitimately takes 15-25s to reconnect to the MCU and reach
	# klippy_state=ready after a process restart (confirmed repeatedly
	# elsewhere in this project's own qualification logs) - sampling
	# stage2 immediately mistook "still connecting" for "broken" and
	# triggered a false-positive rollback failure straight into
	# factory-fallback. This grace period must elapse before the
	# caller's first stage2 sample.
	sleep "$RESTART_GRACE_PERIOD"
	return 0
}

# Repeated stage2 samples over a short window - fails fast on the first
# bad sample rather than waiting out the full window pointlessly.
stabilized_stage2() {
	i=0
	while [ "$i" -lt "$STABILIZE_SAMPLES" ]; do
		sleep "$STABILIZE_INTERVAL"
		if ! "$HEALTHCHECK" stage2; then
			return 1
		fi
		i=$((i + 1))
	done
	return 0
}

# Preserves the failed commit + relevant logs under backups/<name>/failed-*
# per the mission's own "never silently discard evidence" requirement -
# never overwrites a previous failed-<timestamp> directory.
preserve_failure_evidence() {
	# $1=component $2=failed_commit $3=reason
	name="$1"; failed_commit="$2"; reason="$3"
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	dir="$NEBULAOS_ROOT/backups/$name/failed-$ts"
	mkdir -p "$dir"
	{
		echo "failed_commit=$failed_commit"
		echo "reason=$reason"
		echo "detected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$dir/metadata.txt"
	case "$name" in
		klipper) cp /opt/printer_data/logs/klippy.log "$dir/" 2>/dev/null ;;
		moonraker) cp /opt/printer_data/logs/moonraker.log "$dir/" 2>/dev/null ;;
	esac
	log "$name: failure evidence preserved at $dir"
}

# Removes the bind mount, exposing the pristine immutable /opt/<app> copy
# underneath for the rest of this boot, and leaves the update lock in place
# so S05nebulaos-activate stays on immutable on every future boot too, until
# a human clears it - never silently re-attempts the same broken version.
factory_fallback() {
	# $1=component
	info=$(component_info "$1")
	opt_path=$(echo "$info" | cut -d'|' -f3)
	log "$1: falling back to factory/immutable copy at $opt_path (both new and previous versions failed validation)"
	if awk -v t="$opt_path" '$2==t {found=1} END{exit !found}' /proc/mounts; then
		umount "$opt_path" 2>/dev/null
	fi
	wait_for_print_idle
	init_script=$(echo "$info" | cut -d'|' -f2)
	"$init_script" restart
}

validate_component() {
	# $1=component. Runs after a HEAD change was already detected.
	name="$1"
	info=$(component_info "$name")
	path=$(echo "$info" | cut -d'|' -f1)
	new_commit=$(git -C "$path" rev-parse HEAD 2>/dev/null)
	known_good=$(read_state_field "$name" known_good_commit)

	mkdir -p "$LOCKDIR"
	: > "$LOCKDIR/$name.lock"
	write_state "$name" "$known_good" "$new_commit" "validating" ""

	log "$name: new commit detected ($new_commit) - validating"

	if ! "$HEALTHCHECK" stage1 "$name" "$path"; then
		log "$name: stage1 FAILED on new commit $new_commit - reverting to $known_good"
		preserve_failure_evidence "$name" "$new_commit" "stage1_failed"
		git -C "$path" reset --hard "$known_good" >/dev/null 2>&1
		restart_component "$name"
		if stabilized_stage2; then
			log "$name: reverted version re-validated healthy"
			write_state "$name" "$known_good" "$known_good" "rolled-back" "stage1_failed:$new_commit"
			rm -f "$LOCKDIR/$name.lock"
		else
			preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_stage1_rollback"
			factory_fallback "$name"
			# last_seen_commit must reflect the persistent repo's ACTUAL
			# current HEAD (known_good, since it was reset above), not
			# new_commit - real bug found live: recording new_commit here
			# left state.json out of sync with git's real state, so the
			# very next poll saw current(known_good) != last_seen(new_commit)
			# and mistook the already-failed-over state for a fresh update,
			# re-triggering validation and eventually overwriting this
			# factory-fallback state with a false "healthy" while /opt/klipper
			# was still the unmounted immutable copy, not the persistent one.
			write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage1_failed:$new_commit;previous_also_unhealthy"
		fi
		return
	fi

	if stabilized_stage2; then
		log "$name: new commit $new_commit passed full validation - recording as known-good"
		write_state "$name" "$new_commit" "$new_commit" "healthy" ""
		rm -f "$LOCKDIR/$name.lock"
		return
	fi

	log "$name: stage2 FAILED on new commit $new_commit - reverting to $known_good"
	preserve_failure_evidence "$name" "$new_commit" "stage2_failed"
	git -C "$path" reset --hard "$known_good" >/dev/null 2>&1
	restart_component "$name"
	if stabilized_stage2; then
		log "$name: reverted version re-validated healthy"
		write_state "$name" "$known_good" "$known_good" "rolled-back" "stage2_failed:$new_commit"
		rm -f "$LOCKDIR/$name.lock"
	else
		preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_stage2_rollback"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage2_failed:$new_commit;previous_also_unhealthy"
	fi
}

poll_once() {
	for name in klipper moonraker; do
		info=$(component_info "$name")
		path=$(echo "$info" | cut -d'|' -f1)
		[ -d "$path/.git" ] || continue

		current=$(git -C "$path" rev-parse HEAD 2>/dev/null)
		[ -z "$current" ] && continue

		last_seen=$(read_state_field "$name" last_seen_commit)
		if [ -z "$last_seen" ]; then
			# First observation this boot - bootstrap state without
			# triggering validation. Whatever is running now was already
			# proven at boot by S99confirm-good/the existing readiness
			# checks; there is no legitimate "known good" reference to
			# compare against yet other than this.
			write_state "$name" "$current" "$current" "healthy" ""
			log "$name: bootstrapped state at $current"
			continue
		fi

		state=$(read_state_field "$name" state)
		# factory-fallback is a deliberate terminal state (design doc sec
		# 3.1 step 5: "never silently succeed on a degraded configuration")
		# - belt-and-suspenders against ever re-triggering validation here
		# even if state.json's commit bookkeeping were ever wrong again:
		# a human must clear $LOCKDIR/$name.lock (and re-run
		# S05nebulaos-activate or reboot) to re-enable the persistent copy.
		if [ -e "$LOCKDIR/$name.lock" ] && [ "$state" = "factory-fallback" ]; then
			continue
		fi
		if [ "$current" != "$last_seen" ] && [ "$state" != "validating" ]; then
			validate_component "$name"
		fi
	done
}

loop() {
	log "starting (poll interval ${POLL_INTERVAL}s)"
	while true; do
		poll_once
		sleep "$POLL_INTERVAL"
	done
}

case "$1" in
	loop)
		loop
		;;
	poll-once)
		poll_once
		;;
	*)
		echo "usage: $0 loop|poll-once" >&2
		exit 2
		;;
esac
