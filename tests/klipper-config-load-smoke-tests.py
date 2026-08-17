#!/usr/bin/env python3
"""Load the REAL shipped printer.cfg with REAL Klipper, on a real composed tree.

Phase 1 no-fork migration, Phase K (2026-08-17). This closes the one item on
the pre-hardware checklist (analysis mission section 26.1, test 4) that every
other suite in this repository only approaches indirectly: the other tests
check the composition mechanism, the manifest, the Moonraker wiring and the
config file's TEXT. None of them ever asked Klipper itself to load the config.

What this does, and why it is not a simulation
----------------------------------------------
It composes a pristine Klipper3d/klipper checkout at KLIPPER_PIN with a
pristine NebulaOS-klipper-extensions checkout at KLIPPER_EXTENSIONS_PIN using
this repository's own /etc/nebulaos-klipper-compose.sh, writes the chelper
verdict with this repository's own /etc/nebulaos-chelper-preflight.sh, and
then calls Klipper's own klippy.Printer._read_config() against the actual
shipped scripts/build/overlay/opt/printer_data/config/printer.cfg.

That is the same function klippy.py calls on the printer. Every include is
resolved by Klipper's resolver, every section is mapped to a module by
Klipper's load_object() filesystem gate, every module's load_config() runs for
real, and Klipper's own check_unused_options() gets the last word on unknown
sections and unread options.

What it deliberately does NOT cover
-----------------------------------
Everything downstream of "klippy:mcu_identify": MCU pin-name validation,
command lookup against the MCU's data dictionary, and PRTouch's proprietary
message formats. Those need the printer's actual GD32 dictionary, which only
exists on the mainboard and is only obtainable over serial - so they are
hardware tests (section 26.2, tests 4 and 7), not something this can honestly
fake with a hand-written dictionary.

The line is exactly where Klipper itself draws it: _read_config() builds the
whole object graph offline; _connect() then talks to the MCU.

Host prerequisites
------------------
Klippy's own runtime dependencies (greenlet, cffi, jinja2, pyserial) and a
working host gcc. The device ships a CROSS-COMPILED MIPS c_helper.so, which
cannot be loaded here, so this builds a host-native one with Klipper's own
chelper build and then runs the platform's mtime enforcement over it - which
is also what makes the two chelper negatives below real rather than mocked.

If those are missing, every source-derived check reports SKIP rather than
silently passing. To run it with them:

    python3 -m venv /tmp/klippy-venv
    /tmp/klippy-venv/bin/pip install greenlet cffi Jinja2 markupsafe pyserial
    KLIPPY_PYTHON=/tmp/klippy-venv/bin/python \\
        python3 tests/klipper-config-load-smoke-tests.py

Sources are located automatically (vendor/, then the workspace's canonical
checkouts) and can be pointed at explicitly with KLIPPER_SRC and
KLIPPER_EXTENSIONS_SRC.

Usage: python3 tests/klipper-config-load-smoke-tests.py
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKSPACE = REPO_ROOT.parent.parent.parent
MANIFEST = REPO_ROOT / "manifests/dependencies.conf"
CONFIG_DIR = REPO_ROOT / "scripts/build/overlay/opt/printer_data/config"
COMPOSE_SH = REPO_ROOT / "scripts/build/overlay/etc/nebulaos-klipper-compose.sh"
CHELPER_SH = REPO_ROOT / "scripts/build/overlay/etc/nebulaos-chelper-preflight.sh"

PASS = FAIL = SKIP = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"PASS: {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")


def skip(msg):
    global SKIP
    SKIP += 1
    print(f"SKIP: {msg}")


def check(cond, good_msg, bad_msg):
    ok(good_msg) if cond else bad(bad_msg)


def manifest_value(key):
    for line in MANIFEST.read_text().splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return None


def run(cmd, cwd=None, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def git(args, cwd):
    return subprocess.run(["git"] + args, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True).stdout.strip()


def find_source(env_name, candidates, marker):
    env = os.environ.get(env_name)
    paths = [pathlib.Path(env)] if env else []
    paths += candidates
    for c in paths:
        if (c / marker).exists():
            return c
    return None


def klippy_python():
    """The interpreter Klippy itself will run under. Klippy needs greenlet,
    cffi and jinja2; this repository's other tests do not, so it must be
    possible to point at a venv rather than requiring the host python to carry
    Klipper's dependency set."""
    cand = os.environ.get("KLIPPY_PYTHON", sys.executable)
    probe = run([cand, "-c", "import greenlet, cffi, jinja2, serial"])
    return cand if probe.returncode == 0 else None


# The child process. Kept as a separate script rather than an import because
# it must run under KLIPPY_PYTHON (which may be a different interpreter from
# the one running this file), and because Klipper's reactor registers fds and
# greenlets that make a clean in-process teardown unreliable - os._exit() at
# the end is the honest way to leave.
CHILD = r'''
import json, logging, os, sys
klippy_dir = sys.argv[1]
config_file = sys.argv[2]
sys.path.insert(0, klippy_dir)
logging.basicConfig(level=logging.CRITICAL)
result = {}
try:
    import reactor, klippy
    start_args = {'config_file': config_file, 'apiserver': None,
                  'start_reason': 'startup', 'software_version': 'nebulaos-smoke',
                  'cpu_info': 'nebulaos-smoke',
                  'gcode_fd': os.open(os.devnull, os.O_RDONLY)}
    printer = klippy.Printer(reactor.Reactor(), None, start_args)
    printer._read_config()
    result['loaded'] = True
    result['object_count'] = len(printer.objects)
    result['sections'] = sorted(printer.objects.keys())
    sensor = printer.lookup_object('temperature_sensor mcu_temp')
    result['mcu_temp_sensor_class'] = type(sensor.sensor).__name__
    result['mcu_temp_sensor_module'] = type(sensor.sensor).__module__
    heaters = printer.lookup_object('heaters')
    result['sensor_factories'] = sorted(heaters.sensor_factories.keys())
    compat = printer.lookup_object('nebulaos_compat')
    result['compat_status'] = compat.get_status(0)
except BaseException as e:
    result['loaded'] = False
    result['error_type'] = type(e).__name__
    result['error'] = str(e)
sys.stdout.write("@@JSON@@" + json.dumps(result))
sys.stdout.flush()
os._exit(0)
'''


def load_config(py, klipper_dir, config_file, child_path):
    proc = subprocess.run([py, child_path, str(pathlib.Path(klipper_dir) / "klippy"),
                           str(config_file)],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=600)
    out = proc.stdout
    if "@@JSON@@" not in out:
        return {'loaded': False, 'error_type': 'harness',
                'error': (out + proc.stderr)[-2000:]}
    return json.loads(out.split("@@JSON@@", 1)[1])


def main():
    global SKIP

    klipper_pin = manifest_value("KLIPPER_PIN")
    ext_pin = manifest_value("KLIPPER_EXTENSIONS_PIN")
    check(bool(klipper_pin) and bool(ext_pin),
          f"read pins from dependencies.conf: klipper={klipper_pin} "
          f"extensions={ext_pin}",
          "could not read KLIPPER_PIN/KLIPPER_EXTENSIONS_PIN from "
          "manifests/dependencies.conf")
    if not klipper_pin or not ext_pin:
        return

    klipper_src = find_source("KLIPPER_SRC",
                              [REPO_ROOT / "vendor/klipper",
                               WORKSPACE / "_scratch/ref-klipper-mainline"],
                              "klippy/klippy.py")
    ext_src = find_source("KLIPPER_EXTENSIONS_SRC",
                          [REPO_ROOT / "vendor/nebulaos-klipper-extensions",
                           WORKSPACE / "NebulaOS-klipper-extensions"],
                          "nebulaos-extensions.json")
    py = klippy_python()

    if klipper_src is None or ext_src is None:
        skip("no Klipper and/or extensions checkout found - set KLIPPER_SRC "
             "and KLIPPER_EXTENSIONS_SRC, or run scripts/build/"
             "00-fetch-vendor-sources.sh first")
        report()
        return
    if py is None:
        skip("no interpreter with greenlet/cffi/jinja2/pyserial available - "
             "set KLIPPY_PYTHON to a venv that has them (see this file's "
             "docstring). Klippy cannot be started without them, so nothing "
             "below is claimed as passing.")
        report()
        return
    if shutil.which("gcc") is None:
        skip("no host gcc - Klipper's own chelper build cannot produce a "
             "host-native c_helper.so, and the shipped one is MIPS")
        report()
        return

    ok(f"located Klipper source at {klipper_src}")
    ok(f"located extensions source at {ext_src}")
    ok(f"Klippy will run under {py}")

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="klipper-config-load-"))
    try:
        run_suite(tmp, klipper_src, ext_src, klipper_pin, ext_pin, py)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    report()


def run_suite(tmp, klipper_src, ext_src, klipper_pin, ext_pin, py):
    kdir = tmp / "klipper"
    edir = tmp / "extensions"
    cfgdir = tmp / "config"
    child_path = tmp / "child.py"
    child_path.write_text(CHILD)

    # Working copies, so nothing here can ever mutate vendor/ or a canonical
    # checkout. --shared keeps this cheap; --no-hardlinks is not needed since
    # nothing writes into the object store.
    for src, dst, pin, label in ((klipper_src, kdir, klipper_pin, "Klipper"),
                                 (ext_src, edir, ext_pin, "extensions")):
        r = run(["git", "clone", "--quiet", "--shared", str(src), str(dst)])
        if r.returncode != 0:
            bad(f"could not clone a working copy of {label}: {r.stdout[-400:]}")
            return
        r = run(["git", "checkout", "--quiet", pin], cwd=dst)
        if r.returncode != 0:
            bad(f"{label} source does not contain the pinned commit {pin} - "
                f"it is at {git(['rev-parse', 'HEAD'], dst)}. Fetch it, or "
                f"point at a checkout that has it.")
            return
        ok(f"{label} working copy checked out at the pinned commit {pin[:9]}")

    # Point origin at the real remote so anything that reads it (and any
    # future check that does) sees production reality, not a temp path.
    run(["git", "remote", "set-url", "origin",
         "https://github.com/Klipper3d/klipper.git"], cwd=kdir)
    run(["git", "remote", "set-url", "origin",
         "https://github.com/coreflake1/NebulaOS-klipper-extensions.git"],
        cwd=edir)

    # ---- compose, with the platform's own composer -----------------------
    r = run(["sh", "-c", f". {COMPOSE_SH}; compose_ensure '{kdir}' '{edir}'"])
    check(r.returncode == 0,
          "the platform's own compose_ensure() composed the pinned pair",
          f"compose_ensure() failed: {r.stdout[-600:]}")
    if r.returncode != 0:
        return

    check(git(["status", "--porcelain"], kdir) == "",
          "the composed Klipper checkout is git-pristine",
          "the composed Klipper checkout is DIRTY after composition")
    check(git(["status", "--porcelain"], edir) == "",
          "the extensions checkout is git-pristine after composition",
          "the extensions checkout is DIRTY after composition")

    # ---- host-native c_helper.so + the platform's verdict ----------------
    r = run([py, "-c",
             "import sys; sys.path.insert(0, sys.argv[1]); "
             "import chelper; chelper.get_ffi()", str(kdir / "klippy")])
    check(r.returncode == 0,
          "Klipper's own chelper build produced a host-native c_helper.so",
          f"chelper build failed: {r.stdout[-600:]}")
    if r.returncode != 0:
        return

    r = run(["sh", "-c", f". {CHELPER_SH}; chelper_write_verdict '{kdir}'"])
    check(r.returncode == 0,
          "the platform's chelper_write_verdict() reported the mtime "
          "invariant as satisfied",
          f"chelper_write_verdict() did not pass: {r.stdout[-600:]}")
    verdict_path = kdir / ".nebulaos-chelper-verdict.json"
    check(verdict_path.is_file(),
          "the verdict file the manifest names is present in the checkout",
          "the verdict file was not written")

    shutil.copytree(CONFIG_DIR, cfgdir)
    printer_cfg = cfgdir / "printer.cfg"

    # ---- the positive case ----------------------------------------------
    res = load_config(py, kdir, printer_cfg, child_path)
    check(res.get('loaded') is True,
          f"REAL Klipper loaded the REAL shipped printer.cfg with no "
          f"config error ({res.get('object_count')} printer objects created)",
          f"the shipped printer.cfg FAILED to load: "
          f"{res.get('error_type')}: {res.get('error')}")
    if not res.get('loaded'):
        return

    # _read_config() ends with check_unused_options(), so reaching this point
    # is itself the proof that no section was unknown and no option unread.
    ok("Klipper's own check_unused_options() accepted every section and "
       "every option - no unknown section, no unparsed option")

    check(res.get('mcu_temp_sensor_module') == 'extras.nebulaos_temperature_mcu',
          "[temperature_sensor mcu_temp] resolved sensor_type "
          "'nebulaos_temperature_mcu' to the NebulaOS module "
          f"({res.get('mcu_temp_sensor_class')})",
          f"mcu_temp resolved to the wrong module: "
          f"{res.get('mcu_temp_sensor_module')}")

    factories = res.get('sensor_factories') or []
    check('nebulaos_temperature_mcu' in factories,
          "the NebulaOS GD32 sensor type is registered with [heaters]",
          "the NebulaOS GD32 sensor type is NOT registered with [heaters]")
    check('temperature_mcu' in factories,
          "upstream's own temperature_mcu factory is still present and "
          "untouched - the NebulaOS type is an addition, not a replacement",
          "upstream's temperature_mcu factory is missing, which would mean "
          "the extension set is shadowing core Klipper rather than extending it")

    status = res.get('compat_status') or {}
    check(status.get('status') == 'ok',
          "the [nebulaos_compat] preflight ran inside the loading process "
          "and reported ok",
          f"the preflight did not report ok: {status.get('status')}")
    check(status.get('installed_klipper_commit') == status.get(
              'qualified_klipper_commit') == klipper_pin_of(status),
          "the preflight identified the installed Klipper as exactly the "
          f"qualified commit ({status.get('installed_klipper_commit', '')[:9]})",
          f"preflight commit mismatch: installed="
          f"{status.get('installed_klipper_commit')} "
          f"qualified={status.get('qualified_klipper_commit')}")
    check(status.get('verified_composed_modules', 0) > 0,
          f"the in-process composition guard verified "
          f"{status.get('verified_composed_modules')} runtime modules as "
          f"symlinks resolving into the extensions repository",
          "the in-process composition guard verified nothing")

    check(git(["status", "--porcelain"], kdir) == ""
          and git(["describe", "--always", "--dirty"], kdir).endswith(
              klipper_pin[:9]),
          "the Klipper checkout is STILL git-pristine after a full config "
          "load - loading the config leaves no trace in the tree",
          "the Klipper checkout became dirty during the config load")
    check(git(["status", "--porcelain"], edir) == "",
          "the extensions checkout is STILL git-pristine after a full "
          "config load",
          "the extensions checkout became dirty during the config load")

    # ---- negative: the platform's verdict is missing ---------------------
    # Section 26.1 test 13 wants the chelper failure to surface at preflight
    # rather than as a gcc crash mid-boot. This is that assertion, made
    # against a real load rather than a unit-test stub.
    saved = verdict_path.read_text()
    verdict_path.unlink()
    res_missing = load_config(py, kdir, printer_cfg, child_path)
    err = (res_missing.get('error') or '')
    check(res_missing.get('loaded') is False and 'chelper' in err
          and 'has not written it' in err,
          "with the platform verdict absent, the config load REFUSES with a "
          "named chelper preflight error (not a gcc rebuild attempt)",
          f"a missing chelper verdict did not produce the expected refusal: "
          f"loaded={res_missing.get('loaded')} err={err[:300]}")
    verdict_path.write_text(saved)

    # ---- negative: a chelper source is newer than the prebuilt .so -------
    src_c = sorted((kdir / "klippy/chelper").glob("*.c"))[0]
    src_c.touch()
    r = run(["sh", "-c", f". {CHELPER_SH}; chelper_write_verdict '{kdir}'"])
    check(r.returncode != 0,
          f"touching {src_c.name} newer than c_helper.so makes the "
          f"platform's own check fail, loudly, at packaging/activation time",
          "a stale chelper source did NOT fail the platform check")
    res_stale = load_config(py, kdir, printer_cfg, child_path)
    err = (res_stale.get('error') or '')
    check(res_stale.get('loaded') is False and 'chelper' in err,
          "and the resulting 'stale' verdict makes the config load REFUSE "
          "before Klipper can shell out to a gcc this device does not have",
          f"a stale chelper verdict did not stop the config load: "
          f"loaded={res_stale.get('loaded')} err={err[:300]}")
    # restore
    run([py, "-c",
         "import sys; sys.path.insert(0, sys.argv[1]); "
         "import chelper; chelper.get_ffi()", str(kdir / "klippy")])
    run(["sh", "-c", f". {CHELPER_SH}; chelper_enforce_mtime '{kdir}'"])
    run(["sh", "-c", f". {CHELPER_SH}; chelper_write_verdict '{kdir}'"])

    # ---- negative: a managed module is shadowed by a regular file --------
    # The silent failure from section 8.3 of the analysis: git replaces a
    # managed symlink with an upstream regular file at exit code 0. The
    # platform catches it before Klippy starts; this asserts the second layer
    # catches it from INSIDE the loading process too.
    shadowed = kdir / "klippy/extras/tmcstatus.py"
    shadowed.unlink()
    shadowed.write_text("# an upstream file that silently took this name\n")
    res_shadow = load_config(py, kdir, printer_cfg, child_path)
    err = (res_shadow.get('error') or '')
    check(res_shadow.get('loaded') is False and 'SHADOWED' in err,
          "a managed module replaced by a regular file is caught during the "
          "config load and refuses to start, naming the shadowed module",
          f"a shadowed module did not stop the config load: "
          f"loaded={res_shadow.get('loaded')} err={err[:300]}")


def klipper_pin_of(status):
    return status.get('qualified_klipper_commit')


def report():
    print()
    print(f"klipper-config-load-smoke-tests: {PASS} passed, {FAIL} failed, "
          f"{SKIP} skipped")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
