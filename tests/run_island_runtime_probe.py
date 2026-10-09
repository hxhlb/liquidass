#!/usr/bin/env python3.11
"""Run the read-only snapshot through the approved frida13pm tunnel helper.

The helper supplies --host. Never store the device's IP in this script/output.
"""
import argparse
import json
from pathlib import Path
import threading

import frida


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--list-only", action="store_true")
    parser.add_argument("targets", nargs="*", default=["SpringBoard", "MediaRemoteUI"])
    args = parser.parse_args()
    if frida.__version__ != "16.1.4":
        raise RuntimeError(f"Expected Frida 16.1.4, got {frida.__version__}")
    device = frida.get_device_manager().add_remote_device(args.host)
    processes = device.enumerate_processes()
    relevant = [dict(pid=p.pid, name=p.name) for p in processes
                if any(token in p.name.lower() for token in
                       ("springboard", "mediaremote", "replay", "record", "chronod", "widgetrenderer"))]
    print(json.dumps({"client": frida.__version__, "processes": relevant}), flush=True)
    if args.list_only:
        return
    code = Path(__file__).with_name("island_runtime_state.js").read_text()
    for target in args.targets:
        matches = [p for p in processes if p.name == target or str(p.pid) == target]
        if len(matches) != 1:
            print(json.dumps({"target": target, "error": "target missing or ambiguous; no process spawned"}), flush=True)
            continue
        session = None
        script = None
        event = threading.Event()
        def received(message, data):
            print(json.dumps({"target": target, "message": message}, ensure_ascii=False), flush=True)
            event.set()
        try:
            session = device.attach(matches[0].pid)
            script = session.create_script(code)
            script.on("message", received)
            script.load()
            if not event.wait(15):
                print(json.dumps({"target": target, "error": "snapshot timeout"}), flush=True)
        finally:
            if script:
                script.unload()
            if session:
                session.detach()


if __name__ == "__main__":
    main()
