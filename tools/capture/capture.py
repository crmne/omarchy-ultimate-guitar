#!/usr/bin/python3
"""Capture the real reader with an invented track, never touching players or the network.

Run through a GPU lock (see docs in README). Needs the installed Omarchy shell,
Quickshell, and an OpenGL-capable GPU; refuses a software-rendered capture.

Production BarWidget.qml, TabView.qml, Service.qml and Model.js are copied into
a temporary host with its own HOME. In the copies only the plumbing changes:
the service's MPRIS source becomes a plain list the host fills with a fixture
player, its helper runs are removed (so nothing is ever fetched), and the
shell's PopupCard, a layer-shell popup the offscreen platform cannot create,
becomes a floating window with its card kept verbatim.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent
SHELL = Path("/usr/share/omarchy/shell")


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit("expected exactly one %r" % old)
    return text.replace(old, new)


def drop_block(text, start_pattern):
    match = re.search(start_pattern, text, re.M)
    if not match:
        raise SystemExit("pattern not found: " + start_pattern)
    depth = 0
    for j in range(text.index("{", match.start()), len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[:match.start()] + text[text.index("\n", j) + 1:]
    raise SystemExit("unbalanced block")


def offscreen_popup_card(text):
    text = replace_once(text, "import Quickshell.Hyprland\n", "")
    text = replace_once(text, "PopupWindow {\n  id: root\n",
                        "FloatingWindow {\n  id: root\n"
                        "  property alias captureCard: card\n"
                        "  readonly property var captureContent: contentHolder.children[0]\n")
    text = drop_block(text, r"^  HyprlandFocusGrab \{")
    text = drop_block(text, r"^  anchor \{")
    return text


def fixture_service(text):
    text = replace_once(text, "import Quickshell.Services.Mpris\n", "")
    text = replace_once(text, "readonly property var players: Mpris.players ? Mpris.players.values : []",
                        "property var players: []")
    text = replace_once(text, "MprisPlaybackState.Stopped", "0")
    text = replace_once(text, "function runHelper(proc, action, value) {",
                        "function runHelper(proc, action, value) {\n    return")
    return text


def wait_for(predicate, description, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.1)
    raise RuntimeError("Timed out: " + description)


def complete_png(path):
    if not path.exists() or path.stat().st_size < 12:
        return False
    with path.open("rb") as image:
        image.seek(-12, 2)
        return image.read() == b"\x00\x00\x00\x00IEND\xaeB`\x82"


PROBE = r'''import json, os, sys
chain, pid = [], os.getpid()
while pid > 1 and len(chain) < 4:
    with open("/proc/%d/cmdline" % pid, "rb") as f:
        chain.append(f.read().decode("utf-8", "replace").split("\0"))
    with open("/proc/%d/stat" % pid) as f:
        pid = int(f.read().rsplit(")", 1)[1].split()[1])
print(json.dumps({"argv": sys.argv[1:], "query": os.environ.get("UG_TABS_QUERY"),
                  "url": os.environ.get("UG_TABS_URL"), "cmdlines": chain}))
'''


def main():
    output = ROOT / "screenshots"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ug-capture-") as work_path:
        work = Path(work_path)
        home, shell = work / "home", work / "shell"
        # Quickshell's IPC socket lives here, and a socket path has to be short.
        runtime = Path(tempfile.mkdtemp(prefix="ug-capture-", dir=os.environ.get("XDG_RUNTIME_DIR")))
        shell.mkdir()
        theme = home / ".local/state/omarchy/current/next-theme"
        theme.mkdir(parents=True)
        shutil.copy("/usr/share/omarchy/themes/ristretto/colors.toml", theme / "colors.toml")
        env = dict(HOME=str(home), PATH="/usr/bin:/bin", LANG="C.UTF-8",
                   XDG_RUNTIME_DIR=str(runtime), XDG_CACHE_HOME=str(work / "cache"),
                   OMARCHY_PATH="/usr/share/omarchy",
                   # The offscreen platform reaches OpenGL through the X server.
                   DISPLAY=os.environ.get("DISPLAY", ":0"))
        if "XAUTHORITY" in os.environ:
            env["XAUTHORITY"] = os.environ["XAUTHORITY"]
        subprocess.run(["omarchy-theme-set-templates"], env=env, check=True, stdout=subprocess.DEVNULL)
        shutil.copytree(theme, theme.with_name("theme"))
        fonts = home / ".config/fontconfig"
        fonts.mkdir(parents=True)
        (fonts / "fonts.conf").write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>
<include ignore_missing="yes">/etc/fonts/fonts.conf</include>
<match target="pattern"><test name="family"><string>monospace</string></test>
<edit name="family" mode="assign" binding="strong"><string>JetBrainsMono Nerd Font</string></edit></match>
</fontconfig>''')
        for name in ["Commons", "Ui"]:
            shutil.copytree(SHELL / name, shell / name)
        card = shell / "Ui/PopupCard.qml"
        card.write_text(offscreen_popup_card(card.read_text()))

        plugin = work / "plugin"
        plugin.mkdir()
        shutil.copy(TOOLS / "Probe.qml", plugin / "Probe.qml")
        for name in ["BarWidget.qml", "TabView.qml", "Model.js"]:
            shutil.copy(ROOT / name, plugin / name)
        (plugin / "Service.qml").write_text(fixture_service((ROOT / "Service.qml").read_text()))
        shutil.copy(TOOLS / "shell.qml", shell / "shell.qml")
        (work / "probe.py").write_text(PROBE)
        (work / "screen.json").write_text(json.dumps({"screens": [dict(
            name="CAPTURE", x=0, y=0, width=2800, height=1800,
            logicalDpi=96, logicalBaseDpi=96, dpr=1)]}))
        env.update(QT_QPA_PLATFORM="offscreen:configfile=%s" % (work / "screen.json"),
                   QT_QUICK_BACKEND="rhi", QSG_RHI_BACKEND="opengl", QSG_INFO="1",
                   QT_SCALE_FACTOR="2",
                   # Set only so the probe can show the shell removes it.
                   UG_TABS_URL="inherited-and-must-not-arrive",
                   UG_CAPTURE_PLUGIN=str(plugin),
                   UG_CAPTURE_FIXTURES=str(TOOLS / "fixtures.json"),
                   UG_CAPTURE_COVER=str(TOOLS / "cover.svg"),
                   UG_CAPTURE_OUTPUT=str(output),
                   UG_CAPTURE_WALLPAPER="/usr/share/omarchy/themes/ristretto/backgrounds/0-launch.png")
        log = work / "qs.log"

        def call(method, *args):
            result = subprocess.run(["qs", "ipc", "-p", str(shell), "call", "--", "capture", method,
                                     *map(str, args)], env=env, capture_output=True, text=True, timeout=10)
            if result.returncode != 0:
                if method != "ready":
                    print(result.stderr, file=sys.stderr, flush=True)
                return ""
            return result.stdout.strip()

        def grab(name):
            time.sleep(.8)
            path = output / name
            path.unlink(missing_ok=True)
            result = call("grab", str(path))
            if result != "ok":
                raise RuntimeError(result)
            wait_for(lambda: complete_png(path), name)
            print(path, file=sys.stderr, flush=True)

        with log.open("w") as stream:
            proc = subprocess.Popen(["qs", "-p", str(shell)], env=env, stdout=stream, stderr=subprocess.STDOUT)
            try:
                wait_for(lambda: call("ready") == "true", "capture host")

                # The production invocation, run by Quickshell's Process.
                print(call("startProbe", work / "probe.py"), file=sys.stderr)
                wait_for(lambda: call("probeResult") != "", "environment probe")
                probe = json.loads(call("probeResult"))
                print(json.dumps(probe, indent=1), file=sys.stderr)
                assert probe["argv"] == ["--no-cache", "search"], probe
                assert probe["query"] == "Marlow Fennick Paper Lighthouse", probe
                assert probe["url"] is None, probe
                assert "Paper Lighthouse" not in json.dumps(probe["cmdlines"]), probe

                print(call("play"), file=sys.stderr)
                time.sleep(1.5)  # past the service's debounce, which would restart a lookup
                state = json.loads(call("loadTab"))
                assert state["state"] == "ready" and state["versions"] > 1, state
                print(call("openInstruments"), file=sys.stderr)
                grab("instruments-card.png")
                listing = output / "instruments-list.png"
                listing.unlink(missing_ok=True)
                print(call("grabInstrumentList", listing), file=sys.stderr)
                wait_for(lambda: complete_png(listing), listing.name)
                call("assembleInstruments")
                time.sleep(.8)
                instruments = output / "instruments.png"
                instruments.unlink(missing_ok=True)
                assert call("grabInstruments", instruments) == "true"
                wait_for(lambda: complete_png(instruments), instruments.name)
                call("closeDropdown")
                call("expand")
                time.sleep(1)
                call("reload")
                wait_for(lambda: call("reopen") == "true", "reloaded widget")
                time.sleep(.5)
                print(call("geometry"), file=sys.stderr)
                grab("expanded.png")

                call("preparePreview")
                time.sleep(1)
                preview = ROOT / "preview.png"
                preview.unlink(missing_ok=True)
                call("grabPreview", str(preview))
                wait_for(lambda: complete_png(preview), "marketplace preview")
                print(preview, file=sys.stderr, flush=True)
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                shutil.rmtree(runtime, ignore_errors=True)
                log_text = log.read_text()
                (output / "capture.log").write_text(log_text)
                for line in log_text.splitlines():
                    if "OpenGL VENDOR" in line or "WARN" in line or "ERROR" in line:
                        print(line, file=sys.stderr)
        if "NVIDIA" not in log_text or "llvmpipe" in log_text:
            raise RuntimeError("Capture must use GPU rendering; inspect screenshots/capture.log")


if __name__ == "__main__":
    main()
