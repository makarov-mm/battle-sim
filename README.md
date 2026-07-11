# Battlefield

An autonomous low-poly 3D battle simulation. Two toy armies, red versus green:
infantry and tanks advance, shoot, throw grenades, die and respawn. Nobody
controls it. The camera flies over the battlefield on its own, finds the
hottest spot and films it with cinematic shots. Pure simulation, no input.

The architecture follows my other real-time projects (Gray-Scott
reaction-diffusion, vortex dynamics): an authoritative **Elixir** server runs
the whole simulation, a **Swift + Metal** macOS client only renders the
interpolated state. Zero external dependencies on either side.

```
Elixir (20 Hz simulation) --binary WebSocket--> Swift/Metal (60 fps, interpolation + FX + camera)
```

## Running it

The easiest way is the scripts in the repo root (make them executable once
with `chmod +x *.sh`):

- `./build.sh` builds the server and, on macOS, the client.
- `./run.sh` (macOS) starts the server in the background, waits for the port,
  launches the client and stops the server on exit.
- `./run-server.sh` runs only the server.
- `./run-client.sh` runs only the client (macOS).

Everything is configurable through environment variables: `PORT` (default
4040), `HOST`, `CONFIG` (`release` or `debug`). Example: `PORT=5000 ./run.sh`.

Manually, in two terminals:

```
cd server
mix run --no-halt
```

```
cd client
swift run -c release
```

Requirements: Elixir 1.14+ for the server, macOS 13+ with the Xcode toolchain
for the client. Start order does not matter, the client reconnects on its own.

`DEBUG_CAM=1 ./run-client.sh` bypasses the camera director and shows a fixed
high orbit of the whole field. Useful for debugging.

## Server architecture

`Battlefield.Sim` is a single GenServer with a fixed 50 ms tick. Agents live
in a flat map, there is no process per agent. Spawning 504 processes for 504
entities would be architectural theater; one process updating a map is cheap
and easy to reason about. Each tick: movement, firing, grenades and tank
shells, damage and deaths, target reacquisition, respawns, then one binary
frame is encoded and broadcast to all clients through a duplicate-key
`Registry`.

`Battlefield.WS` is a WebSocket server written from scratch on top of
`:gen_tcp` (RFC 6455: SHA-1 + Base64 handshake, server-to-client binary
frames, ping/pong/close). Every connection is a process registered in the
Registry; the simulation pushes frames to it with a plain `send`.

`Battlefield.Protocol` encodes the binary frame, little-endian:

```
header:  tick u32 | n_agents u16 | n_events u16
agent:   id u16 | flags u8 | hp u8 | x i16 | z i16 | heading i16       (10 bytes)
event:   type u8 | a u16 | x1 i16 | z1 i16 | x2 i16 | z2 i16 | aux u8  (12 bytes)
```

`flags`: bit 0 team, bits 1-2 kind (0 infantry, 1 tank), bits 3-5 state
(0 moving, 1 firing, 2 throwing, 3 dead). Positions are fixed-point 1/64 m,
heading is radians * 10430. Event types: 0 shot, 1 grenade or shell in flight
(aux = flight time * 20), 2 explosion (aux = radius * 10), 3 death
(aux = team). A full frame with 504 agents is about 5 KB.

## Client architecture

- **Net**: `URLSessionWebSocketTask`, decodes frames with unaligned loads,
  reconnects automatically.
- **World**: keeps the last two snapshots per agent and interpolates between
  them. The client renders roughly one network interval behind the server, so
  20 Hz data turns into smooth 60 fps motion. Respawn teleports are detected
  by a position jump over 8 m and snapped instead of sliding across the map.
  Server events spawn visual effects.
- **CameraDirector**: combat events deposit heat on the field (deaths,
  explosions, grenades, a subsample of shots). The weighted centroid of recent
  heat with exponential decay becomes the point of interest. Every 6 to 10
  seconds the director cuts to a new shot: orbit, flyover, low dolly or crane.
  75% of transitions are hard cuts, the rest glide. When the field is quiet it
  falls back to the centroid of living units, so the camera always has
  something to frame.
- **MeshBuilder / Shaders / Renderer**: instanced rendering. A soldier is
  built from boxes; all animation (walk cycle, aiming, death fall) happens in
  the vertex shader, driven by a per-instance phase value. The tank is hull,
  turret, barrel and tracks. The ground is a single plane with procedural
  value noise, a sandy road band and distance fog. Effects (tracers,
  explosions, grenades in flight, skulls rising over the dead) are billboards
  and ribbons with alpha blending. Shaders are compiled at runtime from an
  embedded source string, which avoids SPM resource bundling issues for a
  command-line executable.

## Tuning

Everything lives in `server/lib/battlefield/sim.ex` as module attributes:

| Parameter | Value | Meaning |
|---|---|---|
| `@tick_ms` | 50 | simulation step (20 Hz) |
| `@field_x` / `@field_z` | 118 / 76 | field half-extents, meters |
| `@inf_per_team` | 250 | infantry per team |
| `@tanks_per_team` | 2 | tanks per team |
| `@inf_speed` / `@inf_range` | 6 / 26 | infantry speed and weapon range |
| `@inf_hp` | 3 | infantry hit points |
| `@tank_speed` / `@tank_range` | 2.5 / 45 | tank speed and range |
| `@tank_hp` | 24 | tank hit points |
| `@respawn_min` / `@respawn_spread` | 2 / 6 | respawn delay, randomized per corpse |

Rifle accuracy is `p = max(0.1, 0.55 - d/55)`. Grenades are only thrown when
the target has a cluster of at least 3 enemies within 6 m. Tank shells are
ballistic AoE projectiles (radius 8). Respawn delays are deliberately
randomized per corpse. The first version respawned everyone after a fixed
delay, and both armies annihilated each other in synchronized waves: pulses of
total extinction instead of a rolling front line. Randomized respawns plus
deep spawn bands turned it into a continuous grinder, which is what you want
to watch.

## A bug worth remembering

The first run on real hardware showed mostly empty frames with an occasional
working scene. The cause turned out to be a handedness mismatch: the lookAt
matrix was right-handed while the projection matrix was left-handed.
Everything in front of the camera received negative clip-space w and was
culled entirely. The renderer was actually drawing whatever happened to be
behind the camera, mirrored. The rare "working" frames were moments when the
camera accidentally faced away from the battle. One sign flip in one matrix
explained every symptom at once.

## Ideas for later

- A killfeed overlay. Death events already arrive, only a text layer is
  missing.
- A web viewer (WebGL or Three.js) speaking the same binary protocol, so the
  simulation can be watched in a browser without building anything.
- An optional external signal mode: a separate module could modulate
  reinforcements or morale from an outside data stream without touching the
  combat core. The current build intentionally stays a pure autonomous
  simulation.
