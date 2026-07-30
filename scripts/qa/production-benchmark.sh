#!/bin/sh
# NebulaOS production optimization mission, Phase 2 (2026-07-30).
#
# Captures one consistent, repeatable resource-usage snapshot of the real
# running device, meant to be scp'd over and run directly ON the printer
# (BusyBox ash, not bash - no bashisms). Not part of the production
# rootfs overlay - this is a developer/QA tool for A/B-comparing
# optimization candidates, invoked over SSH like any other live-device
# check this project already does.
#
# Usage: production-benchmark.sh <label> [output-dir]
#   <label>       free-text scenario tag, e.g. "idle-10min",
#                 "camera-1080p30", "usb-storage-inserted" - becomes part
#                 of the output filename and the "label" field.
#   [output-dir]  where to write <label>-<timestamp>.tsv/.json/.txt
#                 (default: /usr/data/staging/benchmarks)
#
# Rate-based metrics (CPU%, context-switch rate, interrupt rate) need two
# samples - this script takes them SAMPLE_INTERVAL_SECONDS apart itself,
# so a single invocation is a complete, self-contained snapshot. For a
# scenario like "idle for 10 minutes", start the scenario, wait out the
#10 minutes yourself, then invoke this once at the end - it is not itself
# a 10-minute-long capture.

SAMPLE_INTERVAL_SECONDS=5
LABEL="${1:?usage: production-benchmark.sh <label> [output-dir]}"
OUTDIR="${2:-/usr/data/staging/benchmarks}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BASENAME="$OUTDIR/${LABEL}-${TS}"

mkdir -p "$OUTDIR"

# --- helpers -----------------------------------------------------------

# VmRSS (kB) for the first process whose command line matches $1 (a plain
# substring, not a regex - keeps this BusyBox-grep-safe).
rss_for() {
	pid=$(ps -o pid,args 2>/dev/null | grep -F "$1" | grep -v grep | head -1 | awk '{print $1}')
	[ -z "$pid" ] && { echo "0"; return; }
	awk '/^VmRSS:/{print $2; found=1} END{if(!found) print 0}' "/proc/$pid/status" 2>/dev/null || echo 0
}

pid_for() {
	ps -o pid,args 2>/dev/null | grep -F "$1" | grep -v grep | head -1 | awk '{print $1}'
}

# Sum of the "otg"/dwc2 interrupt line(s) in /proc/interrupts (both CPU
# columns), the largest single concrete finding in the original audit.
otg_interrupt_total() {
	awk '/otg|dwc2/{s=0; for(i=2;i<=NF;i++){if($i ~ /^[0-9]+$/) s+=$i}; total+=s} END{print total+0}' /proc/interrupts
}

ctxt_total() {
	awk '/^ctxt/{print $2}' /proc/stat
}

# Aggregate CPU busy ticks + total ticks from the first "cpu " line.
cpu_ticks() {
	awk '/^cpu /{busy=0; for(i=2;i<=NF;i++){if(i!=5) busy+=$i}; total=busy+$5; print busy" "total}' /proc/stat
}

# --- sample 1 ------------------------------------------------------------

T1=$(date +%s)
OTG1=$(otg_interrupt_total)
CTXT1=$(ctxt_total)
CPU1=$(cpu_ticks)
CPU1_BUSY=${CPU1% *}
CPU1_TOTAL=${CPU1#* }

sleep "$SAMPLE_INTERVAL_SECONDS"

# --- sample 2 + instantaneous metrics -------------------------------------

T2=$(date +%s)
OTG2=$(otg_interrupt_total)
CTXT2=$(ctxt_total)
CPU2=$(cpu_ticks)
CPU2_BUSY=${CPU2% *}
CPU2_TOTAL=${CPU2#* }

ELAPSED=$((T2 - T1))
[ "$ELAPSED" -le 0 ] && ELAPSED=1

OTG_RATE=$(( (OTG2 - OTG1) / ELAPSED ))
CTXT_RATE=$(( (CTXT2 - CTXT1) / ELAPSED ))
CPU_BUSY_DELTA=$((CPU2_BUSY - CPU1_BUSY))
CPU_TOTAL_DELTA=$((CPU2_TOTAL - CPU1_TOTAL))
[ "$CPU_TOTAL_DELTA" -le 0 ] && CPU_TOTAL_DELTA=1
CPU_PCT=$(( (CPU_BUSY_DELTA * 100) / CPU_TOTAL_DELTA ))

UPTIME_S=$(awk '{print int($1)}' /proc/uptime)
LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
LOAD15=$(awk '{print $3}' /proc/loadavg)
THREAD_COUNT=$(awk '{print $4}' /proc/loadavg | cut -d/ -f2)

# Plain pipe, not <(...) - process substitution isn't BusyBox-ash-safe.
MEM_LINE=$(free -m | awk '/^Mem:/{print $2, $3, $4, $6, $7}')
MEM_TOTAL=$(echo "$MEM_LINE" | awk '{print $1}')
MEM_USED=$(echo "$MEM_LINE" | awk '{print $2}')
MEM_FREE=$(echo "$MEM_LINE" | awk '{print $3}')
MEM_BUFFCACHE=$(echo "$MEM_LINE" | awk '{print $4}')
MEM_AVAILABLE=$(echo "$MEM_LINE" | awk '{print $5}')
SWAP_LINE=$(free -m | awk '/^Swap:/{print $2, $3}')
SWAP_TOTAL=$(echo "$SWAP_LINE" | awk '{print $1}')
SWAP_USED=$(echo "$SWAP_LINE" | awk '{print $2}')

SOCKET_COUNT=$(ss -tln 2>/dev/null | tail -n +2 | wc -l)

KLIPPY_RSS=$(rss_for "klippy.py")
MOONRAKER_RSS=$(rss_for "moonraker.py")
GUPPYSCREEN_RSS=$(rss_for "/opt/guppyscreen/guppyscreen")
USTREAMER_RSS=$(rss_for "ustreamer")
NGINX_RSS=$(rss_for "nginx: master")
DROPBEAR_RSS=$(rss_for "/usr/sbin/dropbear -R")
MODEMMANAGER_RSS=$(rss_for "ModemManager")
DBUS_RSS=$(rss_for "dbus-daemon")

USTREAMER_PID=$(pid_for "ustreamer")
if [ -n "$USTREAMER_PID" ]; then
	USTREAMER_CPU_STAT=$(awk '{print $14+$15}' "/proc/$USTREAMER_PID/stat" 2>/dev/null)
else
	USTREAMER_CPU_STAT=""
fi

MOONRAKER_INFO=$(curl -s --max-time 3 "http://127.0.0.1:7125/server/info" 2>/dev/null)
PRINTER_STATE=$(curl -s --max-time 3 "http://127.0.0.1:7125/printer/objects/query?webhooks" 2>/dev/null)

USB_TOPOLOGY=$(lsusb -t 2>/dev/null)

# --- write TSV row (one line, easy to diff/append across runs) ---------

TSV="$BASENAME.tsv"
if [ ! -e "$OUTDIR/summary.tsv" ]; then
	printf 'timestamp\tlabel\tuptime_s\tload1\tload5\tload15\tthreads\tmem_total_mb\tmem_used_mb\tmem_free_mb\tmem_buffcache_mb\tmem_available_mb\tswap_total_mb\tswap_used_mb\tcpu_pct\tctxt_per_sec\totg_irq_per_sec\tsocket_count\tklippy_rss_kb\tmoonraker_rss_kb\tguppyscreen_rss_kb\tustreamer_rss_kb\tnginx_rss_kb\tdropbear_rss_kb\tmodemmanager_rss_kb\tdbus_rss_kb\tustreamer_cpu_ticks\n' \
		> "$OUTDIR/summary.tsv"
fi
ROW=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
	"$TS" "$LABEL" "$UPTIME_S" "$LOAD1" "$LOAD5" "$LOAD15" "$THREAD_COUNT" \
	"$MEM_TOTAL" "$MEM_USED" "$MEM_FREE" "$MEM_BUFFCACHE" "$MEM_AVAILABLE" \
	"$SWAP_TOTAL" "$SWAP_USED" "$CPU_PCT" "$CTXT_RATE" "$OTG_RATE" "$SOCKET_COUNT" \
	"$KLIPPY_RSS" "$MOONRAKER_RSS" "$GUPPYSCREEN_RSS" "$USTREAMER_RSS" "$NGINX_RSS" \
	"$DROPBEAR_RSS" "$MODEMMANAGER_RSS" "$DBUS_RSS" "${USTREAMER_CPU_STAT:-0}")
printf '%s\n' "$ROW" >> "$OUTDIR/summary.tsv"
printf '%s\n' "$ROW" > "$TSV"

# --- write readable summary ---------------------------------------------

SUMMARY="$BASENAME.txt"
{
	echo "NebulaOS production benchmark - $LABEL ($TS)"
	echo "sample interval: ${ELAPSED}s"
	echo
	echo "uptime: ${UPTIME_S}s   load: $LOAD1 $LOAD5 $LOAD15   threads: $THREAD_COUNT"
	echo "memory: total=${MEM_TOTAL}MB used=${MEM_USED}MB free=${MEM_FREE}MB buff/cache=${MEM_BUFFCACHE}MB available=${MEM_AVAILABLE}MB"
	echo "swap: total=${SWAP_TOTAL}MB used=${SWAP_USED}MB"
	echo "cpu: ${CPU_PCT}% aggregate busy over sample window"
	echo "context switches: ${CTXT_RATE}/sec"
	echo "USB OTG interrupts: ${OTG_RATE}/sec"
	echo "listening sockets: $SOCKET_COUNT"
	echo
	echo "RSS (kB): klippy=$KLIPPY_RSS moonraker=$MOONRAKER_RSS guppyscreen=$GUPPYSCREEN_RSS ustreamer=$USTREAMER_RSS nginx=$NGINX_RSS dropbear=$DROPBEAR_RSS modemmanager=$MODEMMANAGER_RSS dbus=$DBUS_RSS"
	echo "ustreamer cumulative cpu ticks (utime+stime): ${USTREAMER_CPU_STAT:-n/a}"
	echo
	echo "USB topology:"
	echo "$USB_TOPOLOGY"
	echo
	echo "Moonraker /server/info:"
	echo "$MOONRAKER_INFO"
	echo
	echo "Printer webhooks state:"
	echo "$PRINTER_STATE"
} > "$SUMMARY"

echo "wrote $TSV"
echo "wrote $SUMMARY"
echo "appended $OUTDIR/summary.tsv"
