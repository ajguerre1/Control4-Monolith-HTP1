"""A local stand-in for a Monolith HTP-1, for driver-level testing.

Speaks the real protocol -- getmso / mso / changemso / msoupdate / error
"bad-verb" -- from an invented document, so the live units are never touched.
Fault injection covers what a healthy device will not do on demand.

    python tools/fake-htp1.py                 # serve on 127.0.0.1:8080
    python tools/fake-htp1.py --port 8123
    python tools/fake-htp1.py --fault drop-mid-frame
    python tools/fake-htp1.py --fault trickle      # one byte per write
    python tools/fake-htp1.py --fault ignore-ping  # never answer a ping

Nothing here contains site data: the document is invented, matching the shape of
firmware 2.x.
"""

import argparse
import asyncio
import json

import websockets

DOCUMENT = {
    "volume": -25,
    "muted": False,
    "powerIsOn": True,
    "powerAction": "none",
    "input": "h1",
    "unitname": "Processor",
    "upmix": {"select": "dolby", "dolby": {"cs": False}, "dts": {"ws": True}},
    "cal": {"vpl": -50, "vph": 0, "zeroPoint": 0, "diracactive": "on", "currentdiracslot": 0},
    "inputs": {
        "h1": {"label": "Streamer", "visible": True},
        "h2": {"label": "Console", "visible": True},
        "a1": {"label": "Turntable", "visible": True},
    },
    "versions": {"avController": "5.96 Built Jan  1 2026, 00:00:00\n", "SerialNumber": "0001"},
    "status": {"SurroundMode": "Dolby Surround", "DECSourceProgram": "PCM"},
    "videostat": {"VideoResolution": "3840x2160p60Hz", "HDRstatus": "HDR10"},
}


def apply_patch(document: dict, op: dict) -> None:
    """Apply one RFC 6902 operation. Only what this fake needs to be honest."""
    path = op.get("path", "")
    segments = [s for s in path.split("/") if s]
    if not segments:
        return
    node = document
    for segment in segments[:-1]:
        node = node.setdefault(segment, {})
    if op.get("op") == "remove":
        node.pop(segments[-1], None)
    else:
        node[segments[-1]] = op.get("value")


class Device:
    def __init__(self, fault: str | None):
        self.document = json.loads(json.dumps(DOCUMENT))
        self.fault = fault
        self.clients: set = set()

    async def broadcast(self, ops: list) -> None:
        message = "msoupdate " + json.dumps(ops)
        for client in list(self.clients):
            try:
                await client.send(message)
            except websockets.ConnectionClosed:
                self.clients.discard(client)

    async def send(self, client, message: str) -> None:
        if self.fault == "trickle":
            # Exercise reassembly: one byte per TCP write.
            for index in range(len(message)):
                await client.send(message[index : index + 1])
            return
        if self.fault == "drop-mid-frame":
            await client.send(message[: len(message) // 2])
            await client.close(code=1006)
            return
        await client.send(message)

    async def handle(self, client) -> None:
        if client.request.path != "/ws/controller":
            await client.close(code=1008, reason="unknown path")
            return

        self.clients.add(client)
        print(f"client connected ({len(self.clients)} total)")
        try:
            async for raw in client:
                verb, _, body = raw.partition(" ")
                if verb == "getmso":
                    await self.send(client, "mso " + json.dumps(self.document))
                elif verb == "changemso":
                    try:
                        ops = json.loads(body)
                    except ValueError:
                        await client.send('error "bad-json"')
                        continue
                    for op in ops:
                        apply_patch(self.document, op)
                        print(f"  {op.get('op')} {op.get('path')} = {op.get('value')!r}")
                    # The real unit echoes every change to every client.
                    await self.broadcast(ops)
                else:
                    await client.send('error "bad-verb"')
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(client)
            print(f"client gone ({len(self.clients)} left)")


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument(
        "--fault",
        choices=["trickle", "drop-mid-frame", "ignore-ping"],
        default=None,
        help="inject a failure a healthy device will not produce on demand",
    )
    args = parser.parse_args()

    device = Device(args.fault)
    # ping_interval None means this server never pings; the driver's own pings
    # are still answered unless the ignore-ping fault is selected.
    ping_interval = None if args.fault == "ignore-ping" else 20
    async with websockets.serve(
        device.handle, args.host, args.port, ping_interval=ping_interval
    ):
        print(f"fake HTP-1 on ws://{args.host}:{args.port}/ws/controller"
              + (f" (fault: {args.fault})" if args.fault else ""))
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
