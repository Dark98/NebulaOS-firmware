#!/usr/bin/env python3
"""Offline validation of the shipped Moonraker configuration for the Klipper
stack. Phase 1 no-fork migration, Phase J.

This does not run Moonraker. It does something more useful for a config file
that has to be right before a printer boots: it re-implements Moonraker's own
include and parse rules, and then checks every option this project sets
against Moonraker's REAL source at the pinned commit - so "these options are
supported" is verified rather than asserted from memory.

That distinction is not theoretical here. The shipped moonraker.conf already
carries a long comment about a previous round of exactly this mistake: seven
options were set on the reserved [update_manager klipper] slot, every one of
them silently ignored, each surfacing as an "Unparsed config option" warning
on every boot of a byte-for-byte fresh install. The checks below exist so
that cannot happen again quietly.

Moonraker's source is located automatically (vendor/moonraker, or the
workspace's reference clone) and can be pointed at explicitly with
MOONRAKER_SRC. Without it the source-derived checks are reported as skipped
rather than silently passing.

Usage: python3 tests/moonraker-klipper-stack-config-tests.py
"""

import configparser
import os
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_DIR = REPO_ROOT / "scripts/build/overlay/opt/printer_data/config"
MOONRAKER_CONF = CONFIG_DIR / "moonraker.conf"
PRINTER_CFG = CONFIG_DIR / "printer.cfg"
MANAGED_DIR = CONFIG_DIR / "nebulaos"

KLIPPER_PIN = "fe4eb8650bd7de4c2100a14eaf09b0965c430e29"
EXTENSIONS_PIN = "9fce9b11588e06835144ce1fee0a19b1204bc543"
OFFICIAL_KLIPPER = "https://github.com/Klipper3d/klipper.git"
EXTENSIONS_ORIGIN = "https://github.com/coreflake1/NebulaOS-klipper-extensions.git"

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


def find_moonraker_source():
    env = os.environ.get("MOONRAKER_SRC")
    candidates = [pathlib.Path(env)] if env else []
    candidates += [
        REPO_ROOT / "vendor/moonraker",
        REPO_ROOT.parent.parent.parent / "_scratch/ref-moonraker",
    ]
    for c in candidates:
        if (c / "moonraker/components/update_manager/common.py").is_file():
            return c
    return None


def parse_like_moonraker(path, visited=None):
    """Mirror ConfigHelper._parse_file's include handling closely enough to be
    meaningful: includes are globbed RELATIVE TO THE INCLUDING FILE's parent,
    an empty glob is a hard error, included sections are not themselves added
    to the parser, and a section repeated within ONE file is an error while
    the same section appearing in two different files is not."""
    visited = visited if visited is not None else []
    path = path.resolve()
    if path in visited:
        raise ValueError(f"recursive include: {path}")
    visited.append(path)

    parser = configparser.ConfigParser(interpolation=None, strict=False)
    buffer, seen_here = [], set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip()[0] in "#;":
            continue
        line = raw.expandtabs(4)
        cmt = re.search(r" +[#;]", line)
        if cmt is not None:
            line = line[: cmt.start()]
        m = re.match(r"\s*\[([^]]+)\]", line)
        if m and m.group(1).startswith("include "):
            inc = m.group(1)[8:].strip()
            if not inc:
                raise ValueError(f"invalid include directive: [{m.group(1)}]")
            paths = sorted(path.parent.glob(inc))
            if not paths:
                raise ValueError(f"no files matching include directive [{m.group(1)}]")
            if buffer:
                parser.read_string("\n".join(buffer), str(path))
                buffer = []
            for p in paths:
                sub = parse_like_moonraker(p, visited)
                for sect in sub.sections():
                    if not parser.has_section(sect):
                        parser.add_section(sect)
                    for k, v in sub.items(sect):
                        parser.set(sect, k, v)
            continue
        if m:
            if m.group(1) in seen_here:
                raise ValueError(f"duplicate section [{m.group(1)}] in file {path}")
            seen_here.add(m.group(1))
        buffer.append(line)
    if buffer:
        parser.read_string("\n".join(buffer), str(path))
    return parser


# --- 1. the config parses at all, the way Moonraker would parse it ---------

try:
    cfg = parse_like_moonraker(MOONRAKER_CONF)
    ok("moonraker.conf parses cleanly under Moonraker's own include/comment rules")
except Exception as exc:  # noqa: BLE001 - the failure text is the useful part
    bad(f"moonraker.conf does not parse: {exc}")
    cfg = configparser.ConfigParser()

check(
    MOONRAKER_CONF.read_text(encoding="utf-8").count("[include nebulaos/") == 1,
    "moonraker.conf carries exactly one managed include directive",
    "expected exactly one [include nebulaos/...] line in moonraker.conf",
)

managed = sorted(MANAGED_DIR.glob("*.conf"))
check(
    bool(managed),
    f"the managed include glob resolves to real shipped files ({', '.join(p.name for p in managed)})",
    "the [include nebulaos/*.conf] glob matches nothing - Moonraker raises "
    "'No files matching include directive' and refuses to start",
)

# --- 2. the reserved klipper slot -----------------------------------------

check(
    cfg.has_section("update_manager klipper"),
    "[update_manager klipper] reaches the parser through the managed include",
    "[update_manager klipper] is missing after include resolution",
)
if cfg.has_section("update_manager klipper"):
    k = dict(cfg.items("update_manager klipper"))
    check(
        k.get("pinned_commit") == KLIPPER_PIN,
        f"Klipper is pinned to the qualified commit {KLIPPER_PIN}",
        f"Klipper pinned_commit is {k.get('pinned_commit')!r}, expected {KLIPPER_PIN}",
    )
    check(
        "origin" not in k,
        "the reserved klipper slot sets no origin - it cannot be overridden, and "
        "Moonraker's hardcoded value is already official Klipper3d/klipper",
        "the reserved klipper slot sets 'origin', which Moonraker silently ignores",
    )

# --- 3. the extensions section --------------------------------------------

SECT = "update_manager nebulaos_klipper_extensions"
check(
    cfg.has_section(SECT),
    f"[{SECT}] reaches the parser through the managed include",
    f"[{SECT}] is missing after include resolution",
)
if cfg.has_section(SECT):
    e = dict(cfg.items(SECT))
    expectations = {
        "type": "git_repo",
        "origin": EXTENSIONS_ORIGIN,
        "primary_branch": "main",
        "managed_services": "klipper",
        "pinned_commit": EXTENSIONS_PIN,
        "path": "/usr/data/nebulaos/apps/nebulaos-klipper-extensions",
    }
    for key, want in expectations.items():
        check(
            e.get(key) == want,
            f"extensions section sets {key} = {want}",
            f"extensions section has {key} = {e.get(key)!r}, expected {want!r}",
        )
    check(
        e.get("primary_branch") == "main",
        "primary_branch is set explicitly - Moonraker defaults it to 'master', "
        "which this repository does not use",
        "primary_branch must be set explicitly for a repo on 'main'",
    )
    check(
        "virtualenv" not in e and "requirements" not in e,
        "no virtualenv/requirements are declared - a pure-Python extras repo needs neither, "
        "and Moonraker only looks for requirements when a virtualenv is configured",
        "virtualenv/requirements should not be set for a pure-Python extras repo",
    )

# --- 4. the two pins are one qualified pair -------------------------------

deps = (REPO_ROOT / "manifests/dependencies.conf").read_text(encoding="utf-8")
check(
    f"KLIPPER_PIN={KLIPPER_PIN}" in deps,
    "moonraker.conf's Klipper pin matches KLIPPER_PIN in manifests/dependencies.conf",
    "moonraker.conf's Klipper pin has drifted from manifests/dependencies.conf",
)
check(
    f"KLIPPER_EXTENSIONS_PIN={EXTENSIONS_PIN}" in deps,
    "moonraker.conf's extensions pin matches KLIPPER_EXTENSIONS_PIN in dependencies.conf",
    "moonraker.conf's extensions pin has drifted from manifests/dependencies.conf",
)
check(
    f"KLIPPER_REPO={OFFICIAL_KLIPPER}" in deps,
    "the firmware pins official Klipper3d/klipper, which is the origin Moonraker's "
    "reserved slot hardcodes anyway - so the 'Unofficial remote url' anomaly the old "
    "fork tripped on every refresh is gone by construction",
    "KLIPPER_REPO is not official Klipper3d/klipper",
)

# --- 5. printer.cfg ordering and sensor type ------------------------------

printer = PRINTER_CFG.read_text(encoding="utf-8")
sections = [m.group(1) for m in re.finditer(r"(?m)^\[([^]]+)\]", printer)]
check(
    "nebulaos_compat" in sections,
    "printer.cfg declares the [nebulaos_compat] preflight section",
    "printer.cfg is missing [nebulaos_compat]",
)
if "nebulaos_compat" in sections:
    idx = sections.index("nebulaos_compat")
    later = sections[idx + 1:]
    check(
        all(not s.startswith("include ") for s in sections[:idx]),
        "[nebulaos_compat] comes before every [include], so the gate runs before any "
        "included file can load a NebulaOS-managed module",
        "an [include] precedes [nebulaos_compat] - guppy_cmd.cfg declares "
        "[gcode_shell_command] sections, which are NebulaOS-managed modules",
    )
    check(
        any(s.startswith("temperature_sensor ") for s in later),
        "[nebulaos_compat] precedes every [temperature_sensor] section",
        "a [temperature_sensor] section precedes [nebulaos_compat]",
    )
check(
    "sensor_type: nebulaos_temperature_mcu" in printer,
    "printer.cfg uses the NebulaOS GD32 sensor type",
    "printer.cfg still uses sensor_type: temperature_mcu, which official Klipper "
    "raises config_error on for GD32 - Klippy would refuse to start",
)
check(
    not re.search(r"(?m)^sensor_type:\s*temperature_mcu\s*$", printer),
    "no bare 'sensor_type: temperature_mcu' remains anywhere in printer.cfg",
    "a bare sensor_type: temperature_mcu is still present",
)

# --- 6. every option is checked against Moonraker's REAL pinned source ----

src = find_moonraker_source()
if src is None:
    skip(
        "Moonraker source not found (set MOONRAKER_SRC) - the source-derived option "
        "checks below did not run"
    )
else:
    common = (src / "moonraker/components/update_manager/common.py").read_text(encoding="utf-8")
    m = re.search(r"OPTION_OVERRIDES\s*=\s*\(([^)]*)\)", common)
    overrides = set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
    check(
        overrides == {"channel", "pinned_commit", "refresh_interval", "report_anomalies"},
        f"read OPTION_OVERRIDES from Moonraker's real source: {sorted(overrides)}",
        f"OPTION_OVERRIDES has changed at this pin: {sorted(overrides)}",
    )
    if cfg.has_section("update_manager klipper"):
        used = set(dict(cfg.items("update_manager klipper")))
        check(
            used <= overrides,
            f"every option on the reserved klipper slot is genuinely overridable: {sorted(used)}",
            f"these options would be silently ignored by Moonraker: {sorted(used - overrides)}",
        )
    check(
        re.search(r'"origin":\s*"https://github\.com/Klipper3d/klipper\.git"', common) is not None,
        "Moonraker's hardcoded klipper origin at this pin IS Klipper3d/klipper",
        "Moonraker's hardcoded klipper origin is not what this design assumes",
    )

    git_dep = (src / "moonraker/components/update_manager/git_deploy.py").read_text(encoding="utf-8")
    app_dep = (src / "moonraker/components/update_manager/app_deploy.py").read_text(encoding="utf-8")
    both = git_dep + app_dep
    if cfg.has_section(SECT):
        # An option is "real" only if the deploy classes actually read it.
        for opt in sorted(dict(cfg.items(SECT))):
            pattern = rf'(get|getboolean|getlist|getchoice|getint|getdict|has_option)\(\s*[\'"]{re.escape(opt)}[\'"]'
            check(
                re.search(pattern, both) is not None,
                f"'{opt}' is really read by GitDeploy/AppDeploy at the pinned Moonraker",
                f"'{opt}' is NOT read by GitDeploy/AppDeploy - it would be an unparsed option",
            )
        m = re.search(r"svc_choices\s*=\s*\[([^\]]*)\]", app_dep)
        choices = m.group(1) if m else ""
        check(
            '"klipper"' in choices,
            "'managed_services: klipper' is a genuinely supported value, so an extensions "
            "update restarts Klippy natively with no NebulaOS code involved",
            f"'klipper' is not among the supported managed_services values: {choices}",
        )
        # pinned_commit must short-circuit the channel logic, otherwise "channel: dev"
        # really would mean "track the branch" and the pin would not hold.
        check(
            re.search(
                r"if self\.pinned_commit is not None:.*?elif self\.channel == Channel\.DEV:",
                git_dep,
                re.S,
            )
            is not None,
            "pinned_commit is evaluated BEFORE the channel branch in "
            "_get_upstream_version(), so the pin - not 'channel: dev' - decides what this "
            "device can update to",
            "pinned_commit no longer short-circuits the channel logic at this pin",
        )

print()
print(f"moonraker-klipper-stack-config-tests: {PASS} passed, {FAIL} failed, {SKIP} skipped")
sys.exit(1 if FAIL else 0)
