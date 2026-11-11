#!/usr/bin/env python3
"""Builds the phone's native mods on this Mac when the phone asks, from anywhere, over Tailscale.

The app (an instance's Native mods page → Build on my Mac) sends the native mods its instances
chose; this runs ios/remote-install.sh --native-from with them: native-build.py builds each set's
game framework, the app is built with them, packed as an .ipa and served at
https://<this Mac>.<tailnet>.ts.net/horizon/ for the phone to install over the air. The phone asks
for the build's progress here and opens that page when it's done.

It listens on this Mac's loopback only and is reached through `tailscale serve` at /horizon-build:
tailnet only, never the internet, and only requests from devices signed in as this Mac's own
Tailscale user are taken (the Tailscale-User-Login header tailscale serve adds). The phone can only
ask for registry native mods by id and version: native-build.py downloads them from the registry
and checks their size and SHA-256, as for a build by cable.

Native mods are unsandboxed code with your rights: starting this with --trust-native-code is your
decision to build the ones your phone picks. One build runs at a time. Keep the Mac awake and on
power (it holds off idle sleep while building, not a closed lid on battery).

Usage: ios/build-server.py --trust-native-code     (Ctrl-C stops it and its tailnet address)
Needs what remote-install.sh needs: Tailscale on the Mac and the phone, HTTPS certificates on.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORK = HERE / "build" / "build-server"
PORT = 8766
PREFIX = "/horizon-build"
MAX_BODY = 256 * 1024
MOD_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
# native-build.py's lines for a mod that didn't build: "  id: why" and "   left out id: why".
FAILED_MOD = re.compile(r"^ {2,3}(left out )?[a-z0-9][a-z0-9_-]*: ")


def tailscale():
    found = shutil.which("tailscale")
    return found or "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


def tailnet():
    """This Mac's tailnet name, whether it has an HTTPS certificate, and its owner's login."""
    status = json.loads(subprocess.run([tailscale(), "status", "--json"], check=True,
                                       capture_output=True, text=True).stdout)
    me = status["Self"]
    host = me["DNSName"].rstrip(".")
    owner = (status.get("User") or {}).get(str(me.get("UserID")), {}).get("LoginName")
    return host, host in (status.get("CertDomains") or []), owner


def instances_from(body):
    """The phone's instances, cut to what a build reads, or ValueError. Only registry ids and
    versions pass: native-build.py looks each one up in the registry."""
    data = json.loads(body)
    out = []
    for inst in data.get("instances", [])[:100]:
        name = str(inst.get("name", ""))[:100]
        mods = []
        for m in (inst.get("nativeMods") or [])[:50]:
            mod_id, version = m.get("id"), m.get("version")
            if not (isinstance(mod_id, str) and MOD_ID.match(mod_id)
                    and isinstance(version, str) and VERSION.match(version)):
                raise ValueError(f"not a registry mod: {mod_id!r} {version!r}")
            mod = {"id": mod_id, "version": version, "name": str(m.get("name", mod_id))[:100]}
            if isinstance(m.get("sha256"), str) and SHA256.match(m["sha256"]):
                mod["sha256"] = m["sha256"]
            mods.append(mod)
        out.append({"name": name, "nativeMods": mods})
    return out


class Builds:
    """The one build at a time and what the phone sees of it."""

    def __init__(self, host):
        self.lock = threading.Lock()
        self.install_url = f"https://{host}/horizon/"
        self.state = {"state": "idle"}

    def status(self):
        with self.lock:
            state = dict(self.state)
        log = WORK / "build.log"
        if state["state"] != "idle" and log.exists():
            lines = [l for l in log.read_text(errors="replace").splitlines() if l.strip()]
            state["log"] = lines[-12:]
            steps = [l[4:] for l in lines if l.startswith("==> ")]
            if steps:
                state["step"] = steps[-1]
            if any(l.startswith("Native mods didn't all build") for l in lines):
                # remote-install.sh builds the app with what did: the phone says what didn't.
                why = [l.strip().removeprefix("left out ") for l in lines if FAILED_MOD.match(l)]
                state["warning"] = "Some native mods didn't build: " + ("; ".join(why[:4]) or "see the log")
        return state

    def start(self, instances):
        with self.lock:
            if self.state["state"] == "building":
                return False
            self.state = {"state": "building", "started": time.time(),
                          "sets": sum(1 for i in instances if i["nativeMods"])}
        WORK.mkdir(parents=True, exist_ok=True)
        request = WORK / "instances.json"
        request.write_text(json.dumps({"instances": instances}, indent=2))
        threading.Thread(target=self._run, args=(request,), daemon=True).start()
        return True

    def _run(self, request):
        with open(WORK / "build.log", "w") as log:
            # caffeinate -i: no idle sleep until the build ends.
            code = subprocess.run(["caffeinate", "-i", "sh", str(HERE / "remote-install.sh"),
                                   "--native-from", str(request)],
                                  stdout=log, stderr=subprocess.STDOUT, cwd=HERE.parent).returncode
        with self.lock:
            self.state.update(finished=time.time(), state="done" if code == 0 else "failed")
            if code == 0:
                self.state["install"] = self.install_url
        print(f"==> Build {'done' if code == 0 else 'failed'} (log: {WORK / 'build.log'})", flush=True)


def handler(builds, owner):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            print("   ", self.address_string(), fmt % args, flush=True)

        def reply(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def route(self):
            # tailscale serve may or may not keep the /horizon-build prefix.
            path = self.path.split("?", 1)[0]
            return path[len(PREFIX):] if path.startswith(PREFIX) else path

        def allowed(self):
            login = self.headers.get("Tailscale-User-Login")
            if owner and login == owner:
                return True
            self.reply(403, {"error": "Only devices signed in to Tailscale as this Mac's user can build here."})
            return False

        def do_GET(self):
            if not self.allowed():
                return
            if self.route() in ("/status", "/status/"):
                self.reply(200, builds.status())
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self):
            if not self.allowed():
                return
            if self.route() not in ("/build", "/build/"):
                return self.reply(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY:
                return self.reply(413, {"error": "request too large"})
            try:
                instances = instances_from(self.rfile.read(length))
            except (ValueError, AttributeError, TypeError) as e:
                return self.reply(400, {"error": f"bad request: {e}"})
            if not builds.start(instances):
                return self.reply(409, {"error": "A build is already running.", **builds.status()})
            print(f"==> Building for {self.headers.get('Tailscale-User-Login')}", flush=True)
            self.reply(202, builds.status())

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--trust-native-code", action="store_true",
                        help="build the native mods the phone picks (they aren't sandboxed)")
    args = parser.parse_args()
    if not args.trust_native_code:
        print("Native mods are native code with your rights, not sandboxed. Building the ones your phone "
              "picks is your decision: start this with --trust-native-code.", file=sys.stderr)
        sys.exit(3)
    try:
        host, certs, owner = tailnet()
    except (OSError, subprocess.CalledProcessError, KeyError, ValueError):
        sys.exit("Tailscale isn't running on this Mac.")
    if not certs:
        sys.exit("HTTPS certificates aren't on for this tailnet: https://login.tailscale.com/admin/dns → "
                 "HTTPS Certificates → Enable.")
    if not owner:
        sys.exit("Couldn't tell which Tailscale user this Mac is signed in as.")

    server = ThreadingHTTPServer(("127.0.0.1", PORT), handler(Builds(host), owner))
    subprocess.run([tailscale(), "serve", "--bg", "--https=443", "--set-path", PREFIX,
                    f"http://127.0.0.1:{PORT}"], check=True, stdout=subprocess.DEVNULL)
    print(f"==> Taking builds from {owner}'s devices at https://{host}{PREFIX}/ (Ctrl-C stops)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        subprocess.run([tailscale(), "serve", "--https=443", "--set-path", PREFIX, "off"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("\n==> Stopped taking builds.")


if __name__ == "__main__":
    main()
