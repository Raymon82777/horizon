#!/usr/bin/env python3
"""Builds the game frameworks for the iPhone instances that chose native mods.

Native mods are patches to the game's Rust source (horizon-mixins bundles), so each set of them is
a game of its own: for every distinct set an instance on the phone chose, this downloads the mods
from Horizon's registry (size and SHA-256 checked), applies them to a copy of this fork's source,
builds that game for iOS and packages it as ios/build/frameworks/HorizonGame-<set>.framework,
which install.sh puts in the app. The app plays each instance with its set's framework
(Instance.gameName in ios/App/Sources/Instances.swift names them the same way).

A mod that doesn't apply to this source on its own is left out and named, as the desktop
launcher does (docs/native-mods.md). Frameworks no instance uses any more are removed.

Native mods are unsandboxed code: building them needs --trust-native-code, the player's decision.

Usage: ios/native-build.py --device UDID [--trust-native-code] [--dry-run]
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
WORK = HERE / "build" / "native"
FRAMEWORKS = HERE / "build" / "frameworks"
INDEX_URL = "https://horizon-rust.github.io/horizon-mods/index.json"
MIXINS_GIT = "https://github.com/horizon-rust/horizon-mixins"
# docs/native-mods.md: the launcher's horizon-mixins (native_mods::MIXINS_REV) for mods that
# don't name one.
MIXINS_REV = "5a64af938ec86b00d53d16a408aabc0038fb3e57"
BUNDLE_ID = "com.raymcdonald.horizon"
# What the staged source leaves out: build output, the player's Mojang files, git, the desktop
# launcher and docs (not part of the game's build).
STAGE_EXCLUDES = ["target", ".git", ".mc", "ios/build", "ios/App/build", "launcher", "docs", "pr-drafts"]


def log(*parts):
    print("==>", *parts, flush=True)


def run(cmd, **kw):
    print("   $", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=True, **kw)


def game_name(mods):
    """Instance.gameName: HorizonGame-<first 6 bytes of SHA-256 of the sorted id@version lines>."""
    lines = sorted(f"{m['id']}@{m['version']}" for m in mods)
    return "HorizonGame-" + hashlib.sha256("\n".join(lines).encode()).hexdigest()[:12]


def phone_instances(device):
    """instances.json from the app's Application Support on the phone."""
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "instances.json"
        run(["xcrun", "devicectl", "device", "copy", "from", "--device", device,
             "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
             "--source", "Library/Application Support/instances.json", "--destination", str(dest)],
            stdout=subprocess.DEVNULL)
        return json.loads(dest.read_text())["instances"]


def registry():
    with urllib.request.urlopen(INDEX_URL, timeout=60) as r:
        return json.load(r)


def fetch_mod(index, choice):
    """The chosen version's .hnmod, checked against the index, unpacked; its mixin bundle dir."""
    project = next((p for p in index["projects"] if p["id"] == choice["id"] and p["kind"] == "native-mod"), None)
    if project is None:
        raise RuntimeError(f"{choice['id']} isn't a native mod in the registry")
    version = next((v for v in project["versions"] if v["version"] == choice["version"]), None)
    if version is None:
        raise RuntimeError(f"{choice['id']} has no version {choice['version']} in the registry")
    file = version["file"]
    revoked = [r for r in index.get("revoked", []) if r["id"] == project["id"]
               and r.get("sha256") in (None, file["sha256"])]
    if revoked:
        raise RuntimeError(f"{project['id']} was taken down: {revoked[0]['reason']}")
    if not file["url"].startswith("https://github.com/"):
        raise RuntimeError(f"{project['id']}: unexpected download address {file['url']}")
    downloads = WORK / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    path = downloads / file["name"]
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != file["sha256"]:
        with urllib.request.urlopen(file["url"], timeout=120) as r:
            data = r.read()
        if len(data) != file["size"] or hashlib.sha256(data).hexdigest() != file["sha256"]:
            raise RuntimeError(f"{project['id']}: the download doesn't match the registry's size and SHA-256")
        path.write_bytes(data)
    unpacked = WORK / "mods" / f"{project['id']}-{version['version']}"
    if not unpacked.exists():
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.startswith("/") or ".." in Path(name).parts:
                    raise RuntimeError(f"{project['id']}: unsafe path {name} in its file")
            z.extractall(unpacked)
    bundle = unpacked / "mixins" / project["id"]
    if not (bundle / "horizon-mixin.toml").is_file():
        raise RuntimeError(f"{project['id']}: no mixins/{project['id']}/horizon-mixin.toml (not a mixin bundle)")
    # native-1/<horizon commit>/<mixins commit>
    parts = (version.get("api") or "").split("/")
    mixins_rev = parts[2] if len(parts) == 3 and len(parts[2]) == 40 else MIXINS_REV
    return {"id": project["id"], "name": project["name"], "bundle": bundle, "mixins": mixins_rev,
            "hooks": version.get("hooks")}


def mixins_tool(rev):
    tool = WORK / "tools" / rev[:12] / "bin" / "horizon-mixins"
    if not tool.exists():
        log(f"Building horizon-mixins {rev[:12]} (once)")
        run(["cargo", "install", "--locked", "--git", MIXINS_GIT, "--rev", rev,
             "--root", str(tool.parent.parent), "horizon-mixins-cli"])
    return tool


def stage_source():
    """This fork's source, copied without build output; unchanged files keep their times."""
    source = WORK / "source"
    excludes = [f"--exclude=/{e}" for e in STAGE_EXCLUDES]
    run(["rsync", "-a", "--delete", *excludes, f"{ROOT}/", f"{source}/"])
    return source


def apply(tool, source, bundles, out):
    mods = WORK / "apply-mods"
    shutil.rmtree(mods, ignore_errors=True)
    mods.mkdir(parents=True)
    for b in bundles:
        shutil.copytree(b["bundle"], mods / b["id"])
    shutil.rmtree(out, ignore_errors=True)
    return subprocess.run([str(tool), "apply", "--workspace", str(source), "--mods", str(mods), "--out", str(out)],
                          capture_output=True, text=True)


def build_set(name, choices, index, trust):
    log(f"{name}: {', '.join(c['id'] + ' ' + c['version'] for c in choices)}")
    mods = [fetch_mod(index, c) for c in choices]
    revs = {m["mixins"] for m in mods}
    tool = mixins_tool(revs.pop() if len(revs) == 1 else MIXINS_REV)
    source = stage_source()
    applied = WORK / "applied"
    result = apply(tool, source, mods, applied)
    left_out = []
    if result.returncode != 0:
        # Which ones don't fit: each alone, as the desktop launcher's isolation does.
        log("Not every mod applies to this source; trying each on its own")
        fits = []
        for m in mods:
            alone = apply(tool, source, [m], applied)
            if alone.returncode == 0:
                fits.append(m)
            else:
                left_out.append((m, (alone.stderr or alone.stdout).strip().splitlines()[-1:] or ["?"]))
        if not fits:
            raise RuntimeError("None of these mods apply to this Horizon:\n" +
                               "\n".join(f"  {m['id']}: {why[0]}" for m, why in left_out))
        mods = fits
        result = apply(tool, source, mods, applied)
        if result.returncode != 0:
            raise RuntimeError("The mods apply alone but not together:\n" + result.stderr[-2000:])
    # The persistent stage: only files whose content changed are written (with the current
    # time), so Cargo recompiles only the crates the mods touch (docs/native-mods.md, #10421).
    stage = WORK / "stage"
    stage.mkdir(parents=True, exist_ok=True)
    run(["rsync", "-r", "--checksum", "--delete", "--links", f"{applied}/", f"{stage}/"])
    log(f"Compiling {name} for iOS (the first native build takes a while)")
    env = dict(os.environ, IPHONEOS_DEPLOYMENT_TARGET="17.0", CARGO_TARGET_DIR=str(WORK / "target"))
    env.pop("SDKROOT", None)
    run(["cargo", "build", "--release", "--locked", "-p", "horizon-ios", "--target", "aarch64-apple-ios",
         "--manifest-path", str(stage / "Cargo.toml")], env=env)
    dylib = WORK / "target" / "aarch64-apple-ios" / "release" / "libhorizon_ios.dylib"
    run([str(HERE / "package-game.sh"), str(dylib), name])
    record = {"mods": [{"id": m["id"], "name": m["name"]} for m in mods],
              "left_out": [{"id": m["id"], "why": why[0]} for m, why in left_out],
              "chosen": choices}
    # Inside the framework, so the app can say what's built in and what was left out.
    (FRAMEWORKS / f"{name}.framework" / "native-mods.json").write_text(json.dumps(record, indent=2))
    for m, why in left_out:
        print(f"   left out {m['id']}: {why[0]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", required=True)
    parser.add_argument("--trust-native-code", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="say what would be built, build nothing")
    parser.add_argument("--rebuild", action="store_true", help="build every set again")
    args = parser.parse_args()

    instances = phone_instances(args.device)
    sets = {}
    for inst in instances:
        mods = inst.get("nativeMods") or []
        if mods:
            sets.setdefault(game_name(mods), (mods, []))[1].append(inst["name"])
    FRAMEWORKS.mkdir(parents=True, exist_ok=True)
    # Frameworks no instance plays any more go (HorizonGame itself is build-rust.sh's).
    for old in FRAMEWORKS.glob("HorizonGame-*.framework"):
        if old.stem not in sets:
            log(f"Removing {old.stem} (no instance uses it now)")
            shutil.rmtree(old)
    todo = {n: s for n, s in sets.items()
            if args.rebuild or not (FRAMEWORKS / f"{n}.framework").is_dir()}
    if not sets:
        log("No instance on the phone chose native mods")
        return
    for name, (mods, names) in sets.items():
        state = "to build" if name in todo else "built"
        log(f"{', '.join(names)}: {', '.join(m['name'] for m in mods)} ({state})")
    if not todo or args.dry_run:
        return
    if not args.trust_native_code:
        print("\nNative mods are native code with your rights, not sandboxed. Building them is your "
              "decision: run again with --trust-native-code to build the sets above.", file=sys.stderr)
        sys.exit(3)
    index = registry()
    failed = False
    for name, (mods, names) in todo.items():
        try:
            build_set(name, mods, index, args.trust_native_code)
        except (RuntimeError, subprocess.CalledProcessError) as e:
            failed = True
            print(f"\n{', '.join(names)}: couldn't build its native mods:\n{e}", file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
