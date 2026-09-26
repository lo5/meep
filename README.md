# Meep-Meep!

Make your agents go meep-meep-meep when active and ping when idle.

A tiny macOS service that plays preloaded sound files on demand over a Unix
domain socket. Sounds are decoded **into memory once at startup**; every
`play()` is ~1 ms and reads nothing from disk, so beeps fire with near-zero
latency.

## Contents

- [Protocol](#protocol)
- [Build](#build)
- [Run](#run)
- [Install](#install)
- [Node.js example](#nodejs-example)
- [Pi Agent Extension](#pi-agent-extension)
- [Notes](#notes)

## Protocol

The service listens on a Unix domain socket (default
`/tmp/meepmeep.sock`). Each connection sends one request as a single JSON
object, optionally followed by a newline:

```json
{"name": "beep.aiff", "volume": 0.5}
```

- `name` — required. The filename from the sounds directory. Both `"beep.aiff"`
  and `"beep"` (without extension) work, as long as the base name is unique.
  Because the name is a JSON string, it may contain spaces or other characters
  that would be ambiguous in a line-based text protocol.
- `volume` — optional. Loudness clamped to `[0.0, 1.0]`: `0.0`–`1.0` used as-is
  (e.g. `0.5`); values below `0.0` clamp to `0.0`; values above `1.0` clamp to
  `1.0`; omitted → plays at **100% volume**.

Every request means **play from the beginning**: any playback of that sound
currently in progress is stopped and rewound first, so it always plays its
full length from the start (it does not layer over itself). A `volume` that
resolves to `0` (including negative values) means **stop** instead of play:

```json
{"name": "beep.aiff", "volume": 0}
```

Sounds do not loop: a sound stops on its own when it reaches the end.

Malformed JSON is silently ignored (nothing plays, no error), as is a request
for an unknown sound name. The connection is closed after the request.

## Build

Requires only the macOS Command Line Tools (Swift 6.x) and `make`. No other
dependencies.

```sh
make build   # release binary
make debug   # debug binary
make clean   # remove build artifacts
```

The release binary ends up at `.build/release/meepmeep`. Run `make` (or
`make help`) on its own to list every available target.

## Run

```
meepmeep [sound-directory] [socket-path]
```

- `sound-directory` — directory scanned at startup; every audio file in it is
  loaded into memory (default: `~/Library/Sounds`). Supported formats: `.aiff`, `.wav`,
  `.au`, `.snd`, `.caf`, `.mp3`, `.m4a`, `.aac`.
- `socket-path` — where the Unix domain socket is created (default:
  `/tmp/meepmeep.sock`). Any stale socket file at that path is removed on
  startup and cleaned up on SIGINT/SIGTERM.

The `~/Library/Sounds` default is deliberate: it's the conventional macOS
location for user alert sounds and is **not** covered by macOS TCC, so the
launchd agent can scan it at startup without triggering a Documents/Desktop/
Downloads permission prompt. Point `sound-directory` at a protected folder
(e.g. `~/Documents/Sounds`) and macOS will ask for access the first time.

Some sample sounds live in the repo's `sounds/` directory. If you want them 
picked up by the default configuration, copy them into your user sounds library:

```sh
mkdir -p ~/Library/Sounds
cp sounds/*.aif ~/Library/Sounds/
```

Example:

```sh
.build/release/meepmeep ~/Library/Sounds
```

Then from another terminal:

```sh
printf '{"name":"beep.aiff","volume":0.4}\n' | nc -U /tmp/meepmeep.sock
printf '{"name":"beep"}\n' | nc -U /tmp/meepmeep.sock
```

## Install

A template plist ships in `LaunchAgent/org.game-over.meepmeep.plist`. The easiest
path is `make install`, which fills in the binary/sound/socket paths and
bootstraps the agent for you. To do it by hand, edit the paths in
`ProgramArguments` (binary, sound directory, socket path), then:

```sh
cp LaunchAgent/org.game-over.meepmeep.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.game-over.meepmeep.plist
```

- `RunAtLoad` starts it at login; `KeepAlive` restarts it if it crashes.
- Logs go to `/tmp/meepmeep.log`.
- To stop and remove:

```sh
launchctl bootout gui/$(id -u)/org.game-over.meepmeep
rm ~/Library/LaunchAgents/org.game-over.meepmeep.plist
```

## Node.js example

The Unix domain socket needs no extra dependencies:

```ts
import { connect } from "node:net";

function play(name: string, volume?: number) {
	const payload = JSON.stringify(
		volume !== undefined ? { name, volume } : { name },
	);
	const sock = connect("/tmp/meepmeep.sock", () => {
		sock.write(payload + "\n");
		sock.end();
	});
	sock.on("error", () => {}); // service down -> silently ignore
}
```

## Pi Agent Extension

Wire the service into the [pi](https://github.com/earendil-works/pi-coding-agent)
agent lifecycle so it beeps as the agent works. Drop this in
`~/.pi/agent/extensions/beep.ts`:

```ts
/**
 * Pi Beep Extension
 *
 * Plays sounds through the meepmeep service (Unix socket at
 * /tmp/meepmeep.sock) at key points in the agent lifecycle.
 *
 */

import { connect } from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SOCKET_PATH = "/tmp/meepmeep.sock";

function play(name: string, volume: number): void {
	const payload = JSON.stringify({ name, volume }) + "\n";
	const sock = connect(SOCKET_PATH, () => {
		sock.write(payload);
		sock.end();
	});
	sock.on("error", () => {}); // service down -> silently ignore
}

export default function (pi: ExtensionAPI) {
	pi.on("message_start", async () => {
		play("tick", 1);
	});

	pi.on("tool_call", async () => {
		play("tock", 1);
	});

	pi.on("agent_settled", async () => {
		play("meep", 1);
	});
}
```

## Notes

- One request per connection; open, write one JSON object, close.
- Sounds are keyed per-instance: each name maps to a single `NSSound`, so a
  sound can never layer over itself. Every request restarts that sound from the
  beginning: any in-flight playback is stopped (`NSSound.stop()` rewinds to 0)
  and started again, so rapid triggers cut the current playback and start over
  rather than collapsing into one. Different names play on separate instances
  and can overlap.
- `volume: 0` is the stop command: it halts playback of that name without
  changing the instance's persisted volume. `NSSound.stop()` is safe to call
  when nothing is playing.
- Sounds do not loop, so each play runs for the file's full duration and then
  stops on its own with no request needed.
- Volume is applied on every restart request: omitted → 100%. A stop request
  (`volume: 0`) leaves the instance's volume untouched, so it does not silence
  a later restart. (Names sharing an instance — e.g. `beep` and `beep.aiff` —
  share this volume state.)
- Unknown/undecodable files in the sound directory are skipped with a warning
  on stderr at startup.
