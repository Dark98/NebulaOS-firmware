#!/usr/bin/env python3

#####################################################################
######## BELT PLUCK TEST — absolute tension target for Cartesian/bed-slinger printers
#####################################################################
#
# Unlike the CoreXY-style belt comparison (graph_belts.py), which compares two
# belts driving the SAME toolhead mass and is invalid on a Cartesian machine
# (X and Y drive different masses through independent belts — their resonance
# curves are expected to differ regardless of tension), this measures ONE
# axis's belt directly: pluck it like a guitar string and read off its own
# fundamental frequency. That frequency depends only on the belt's free span
# length, its known mass-per-length, and its tension — so a target frequency
# for a given span length is an absolute physical answer, not a comparison.
#
# Formula: f = 1/(2L) * sqrt(T/mu)  (L = free span, T = tension, mu = mass/length)
# Community reference point: ~70-90 Hz for a ~300-400mm Cartesian X/Y span.
# We scale that reference range to the printer's actual measured span length
# (frequency scales as 1/L at constant tension) rather than assuming every
# printer's belt span matches the reference.

import argparse
import csv
import sys

import numpy as np

REFERENCE_SPAN_MM = 350.0
REFERENCE_TARGET_LOW_HZ = 70.0
REFERENCE_TARGET_HIGH_HZ = 90.0
TOLERANCE_HZ = 3.0
FREQ_BAND = (10.0, 300.0)


def load_capture(path):
    times, ax, ay, az = [], [], [], []
    with open(path) as f:
        reader = csv.reader(f)
        next(reader)  # header: time,accel_x,accel_y,accel_z
        for row in reader:
            times.append(float(row[0]))
            ax.append(float(row[1]))
            ay.append(float(row[2]))
            az.append(float(row[3]))
    return np.array(times), np.array(ax), np.array(ay), np.array(az)


def find_pluck_time(times, ax, ay, az, sample_rate):
    # A hand pluck is a short, sharp amplitude spike well above the ambient
    # vibration floor. Smooth the magnitude with a 100ms rolling window and
    # take the loudest moment in the capture as the pluck.
    magnitude = np.sqrt(ax**2 + ay**2 + az**2)
    deviation = np.abs(magnitude - np.median(magnitude))
    window = max(int(sample_rate * 0.1), 1)
    rolling = np.convolve(deviation, np.ones(window) / window, mode="same")
    return times[int(np.argmax(rolling))]


def dominant_peak(times, signal, sample_rate, center_time):
    mask = (times > center_time - 0.2) & (times < center_time + 0.8)
    segment = signal[mask]
    if len(segment) < 10:
        return None
    segment = segment - np.mean(segment)
    windowed = segment * np.hanning(len(segment))
    freqs = np.fft.rfftfreq(len(windowed), d=1.0 / sample_rate)
    psd = np.abs(np.fft.rfft(windowed)) ** 2
    in_band = (freqs > FREQ_BAND[0]) & (freqs < FREQ_BAND[1])
    if not in_band.any():
        return None
    return float(freqs[in_band][np.argmax(psd[in_band])])


def estimate_fundamental(times, ax, ay, az, sample_rate, center_time):
    # A belt's harmonics (2x, 3x...) are always higher than its fundamental,
    # but which physical accelerometer axis picks up the fundamental most
    # strongly (vs. mostly showing a harmonic) depends on sensor orientation.
    # Taking the lowest of the three axes' top peaks is a robust way to land
    # on the fundamental without assuming a fixed sensor orientation.
    peaks = [p for p in (dominant_peak(times, s, sample_rate, center_time) for s in (ax, ay, az)) if p is not None]
    return min(peaks) if peaks else None


def target_range_hz(span_mm):
    scale = REFERENCE_SPAN_MM / span_mm
    return REFERENCE_TARGET_LOW_HZ * scale, REFERENCE_TARGET_HIGH_HZ * scale


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_path")
    parser.add_argument("-a", "--axis", default="?")
    parser.add_argument("-s", "--span-mm", type=float, required=True)
    args = parser.parse_args()

    times, ax, ay, az = load_capture(args.csv_path)
    if len(times) < 20:
        print(f'RESULT axis={args.axis} status=error msg="Capture too short — try again"')
        sys.exit(0)

    sample_rate = 1.0 / np.median(np.diff(times))
    pluck_time = find_pluck_time(times, ax, ay, az, sample_rate)
    measured_hz = estimate_fundamental(times, ax, ay, az, sample_rate, pluck_time)

    if measured_hz is None:
        print(f'RESULT axis={args.axis} status=no_signal msg="Could not detect a clear pluck — try a firmer pluck"')
        sys.exit(0)

    low_hz, high_hz = target_range_hz(args.span_mm)
    if measured_hz < low_hz - TOLERANCE_HZ:
        verdict = "TIGHTEN"
    elif measured_hz > high_hz + TOLERANCE_HZ:
        verdict = "LOOSEN"
    else:
        verdict = "GOOD"

    print(
        f"RESULT axis={args.axis} status=ok measured_hz={measured_hz:.1f} "
        f"target_low_hz={low_hz:.1f} target_high_hz={high_hz:.1f} verdict={verdict}"
    )


if __name__ == "__main__":
    main()
