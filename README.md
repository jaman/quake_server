# QuakeServer

The server side of the Quake engine in Elixir. It runs a QuakeC game's levels: spawning,
entities, collision and linking, server physics, monster movement, the builtins, and the
messages the program writes. It serves both id's Quake programs and FTE's extended
programs (FreeHL's, for one).

```elixir
server = QuakeServer.Server.start("e1m1", source: MyGame.Source, skill: 1)
server = QuakeServer.Server.connect(server)
server = QuakeServer.Server.frame(server, 1 / 60, command)
{events, server} = QuakeServer.Server.drain(server)
```

A game supplies its files through a `QuakeServer.Source` (program, maps, models, and
optionally file reads, listings and package names).

## Quake and FTE

* **Quake's builtins** (`QuakeServer.Builtins`) cover numbers 1 to 78.
* **FTE's extension builtins** (`QuakeServer.Extensions`) are grouped by family:
  strings and `sprintf`, maths, entities, settings and info keys, storage (files, hash
  tables, memory, string buffers), effects, messages, models (studio sequences, skeleton
  objects, tags, surfaces) and waypoint routes.
* **Spawning and hooks:** a program with `CheckSpawn` spawns map entities itself; `init`
  and `initents` are called at level start.
* **Player commands:** a program with `SV_RunClientCommand` moves its own players
  (`QuakeServer.Physics.Command`).
* **Console:** `QuakeServer.Console` runs the commands programs queue with `localcmd`
  and the config files they `exec`.
* **Entity networking:** `QuakeServer.Network` keeps each entity's `SendFlags` every
  server frame and, when a player is sent a packet, runs `SendEntity` for the entities
  the player may see under FTE's rules (fat PVS, `pvsflags`, `viewmodelforclient`,
  `tag_entity`, `customizeentityforclient`, dimensions; `QuakeServer.Visibility`).
* **Messages to players:** `QuakeServer.Outbox` holds each player's reliable messages,
  datagram and centerprint until its next packet; `multicast` reaches the players FTE
  would send to (`QuakeServer.Multicast`), and `bprint`, `sprint` and `centerprint`
  write `svc_print` and `svc_centerprint`.
* **The host:** `QuakeServer.Runner` runs a level on its own clock as FTE's host does,
  and sends the player a packet (reliable messages, entity updates, datagram) for each
  command it receives.

Options set what differs between games: the builtins module, hull choice, spawn-flag
filtering, coordinate encoding, statement budget, a data directory for written files,
and a function trace.

## Licence

GPL-2.0-or-later. The server physics, monster movement, the Quake builtins, the
message encodings and the player movement (`QuakeServer.Pmove`, from QuakeWorld) follow
id Software's GPL release of Quake, so this package is a
derivative of it. The FTE extensions follow the behaviour FTE documents in its generated
`fteextensions.qc`.
