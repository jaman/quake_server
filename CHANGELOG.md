# Changelog

## [0.1.1]

### Added

- The console's `restart`, `disconnect` and `killserver` are passed to the host as
  `{:command, line}` events (`QuakeServer.Server.drain/1`).

## [0.1.0]

### Added

- `Runner.start_link(held: true)` keeps the level unloaded until `Runner.load/1`; a
  client that subscribes before then is sent the serverdata when the level loads.
- `c:QuakeServer.Source.replacements/0` (optional): program functions the game runs
  itself, by name. The server's program has them replaced (`QuakeC.Progs.replace/2`) and
  `QuakeServer.Builtins.call/3` runs the game's function when the program calls one.
- `QuakeServer.World.bounds/2`: the box linking an entity would give it now.

- FTE's `setpos` and `noclip` console commands for the player (`QuakeServer.Cheats`).
- `Runner.take/1` gives the level's map.
- `QuakeServer.Animation`: the animation of the entities a program sends itself
  (`frame` as the sequence, `frame1time`, the server's time as `animtime`, and the
  framerate `frame1time` moves at), sampled each server frame and sent to the player
  in each packet's `animation` when the player lacks it, as GoldSrc's engine carries
  `sequence`, `frame`, `animtime` and `framerate`. `QuakeServer.Network.held/2` gives
  the entities a player holds.

- FTE's key bindings: `QuakeServer.Keys` (FTE's key numbers and names, modifiers, and
  the QuakeC key codes), the console's `bind`, `in_bind`, `bindlevel`, `unbind` and
  `unbindall` (`QuakeServer.Console.Bindings`), the bindings kept in the console
  variable table (`QuakeServer.Cvars.binding/3`, `put_binding/5`, `bindings/1`,
  `bindmaps/1`, `put_bindmaps/2`) and written by `cfg_save` while `cfg_save_binds` is
  set.
- The console's `setinfoblob`, and console commands a menu program takes in its
  `m_consolecommand`.
- `QuakeServer.Cvars.put_engine_default/3`, as FTE's `Cvar_SetEngineDefault`.
- `QuakeServer.Extensions.Settings.extension?/1`.
- The engine variables `cfg_save_binds`, `con_maxlines`, `com_protocolname`,
  `fs_basepath`, `fs_gamepath` and `fs_homepath`.

- FTE's common builtins the server lacked, under FTE's server numbers: recoding
  (`QuakeServer.Extensions.Encoding`: `strconv` 224, `strlennocol` 476,
  `strdecolorize` 477, `crc16` 494, `uri_escape` 510, `uri_unescape` 511,
  `argescape` 295, `digest_hex` 639, `digest_ptr`, `base64encode`, `base64decode`,
  `ftou`, `utof`), memory as bytes (`Memory`: `createbuffer`, `memrealloc`,
  `memcmp`, `memstrsize`), JSON (`Json`: `json_parse` and the `json_get_` readers,
  `json_free`, `js_run_script`), files (`Files`: `fwrite`, `search_getfilemtime`,
  `search_fopen`, `fcopy` 650, `frename` 651, `fexists` 653, `rmtree` 654), string
  buffers (`Buffers`: `buf_copy` 463, `buf_sort` 464, `buf_loadfile` 535,
  `buf_writefile` 536, `bufstr_find` 537), entity text (`EntityText`:
  `generateentitydata`, `writetofile` 606, `parseentitydata` 613, `loadfromdata` 529,
  `loadfromfile` 530, `find_list`, `entityprotection`), `abort` 211 and
  `checkcommand` 294 (`Control`), and the network (`Web`: `uri_get` 513 and
  `uri_post`, `netaddress_resolve` 625, `sendpacket` 242). Replies to `uri_get` reach
  `URI_Get_Callback` at the start of a server frame (`QuakeServer.Extensions.Web.run/1`).
- `QuakeServer.Markup`: text with FTE's markup reduced to what it shows.
- `QuakeServer.Extensions.Store`: `entry/3`, `put_entry/4`, `new_handle/1`, `write/3`,
  `remove/2`, `written?/2`, `modified/2`, `buffer_size/1`.
- The `:inets`, `:ssl` and `:public_key` applications start with the server.
- `QuakeServer.Runner` acknowledges the client's commands: a command's `sequence` is
  set as the program's `input_sequence` and sent back with every packet after it runs
  (FTE's `PEXT2_PREDINFO` `last_sequence`, 0 when the program does not run its players'
  commands); a command's integer `msec` is used as given.
- The `cl_netfps` engine variable.

- The server modules that were in ElixirQuake, loading through `QuakeServer.Source`.
- FTE program support: `CheckSpawn` spawning, `init`/`initents`, `SV_RunClientCommand`,
  a console, entity networking (`QuakeServer.Network`), multicast packets, and about 170
  extension builtins (`QuakeServer.Extensions`).
- `Server.open/2`, a bare world for client programs; options `:builtins`, `:budget`,
  `:hull`, `:inhibit`, `:coords`, `:data_dir`, `:trace`.
- `QuakeServer.Pmove`, QuakeWorld player movement for `runstandardplayerphysics`;
  `openportal`, `getlight`, coloured `lightstyle`, `getlightstyle`, `getlightstylergb`,
  `getsurfacepointattribute`, server polygons (`R_BeginPolygon` and the rest) and the
  `physics_` builtins (no rigid-body engine).
- Pushers turn by `avelocity`, swinging and turning what they carry (a client gets
  `fixangle` 2); brush models with angles collide turned.
- `SOLID_BSPTRIGGER` (22): triggers shaped by their brush model; `Q.trigger?/1`,
  `Q.brush?/1`.

- `customphysics`: an entity holding a function there has it run each frame in place of
  its move type.
- `changelevel(map, startspot)` (`QuakeServer.Extensions.Levels`, and the console's
  `changelevel map startspot`); `Server.start/2` options `:startspot` and `:written`;
  `Server.resume/3` for a level kept from before.
- `Models.share/2`: a client world uses its server's model numbers, its own models
  numbered below zero.
- Pushers move and turn as FTE's (`Physics.Push`, `Physics.PushTurn`): riders are moved
  by setting and testing their spot, the clock advances only when the push went through,
  and a pusher its think moved is pushed that far.
- `QuakeServer.Runner`: a level in its own process on its own clock, a physics frame once
  the cvar `sv_mintic` (0.013) has passed, as long as has passed up to `sv_maxtic` (0.1),
  following level changes; thinks repeat within a frame under
  `sv_gameplayfix_multiplethinks` (on). A client takes the world when it is ready
  (`Runner.snapshot/1`), as FTE sends a client its snapshot.
- `Server.release/1`; the runner releases the levels it drops.
- `search_begin` keeps the game files a pattern matches for the server's life.
- FTE's console variables (`QuakeServer.Cvars`): one ETS table any number of processes
  read and write without waiting on each other, so a server, its client program and its
  menu share one set as FTE's single process does (`Server.start/2` and `open/2` option
  `:cvar_table`). FTE's flags (archive, user and server info, read only, map, renderer
  and video latches, not from server, private, ...), defaults and engine defaults,
  second names, descriptions, `Q_atof`/`Q_atoi` values, the engine's checks on
  `r_meshpitch`, `r_meshroll`, `fov` and `viewsize`, `cvar_lockdefaults`,
  `cvar_purgedefaults`, `cvar_resettodefaults_*`, `cvarreset`, latching and
  `Cvar_LockFromServer`.
- `QuakeServer.Cvars.Engine`: the engine variables FTE registers that the server, the
  client and FreeHL's programs and configs name, with FTE's defaults, flags,
  descriptions and second names (`maxplayers` for `sv_playerslots`, `loadas8bit` for
  `s_loadas8bit`, ...).
- `QuakeServer.Autocvars`: a program's `autocvar_` globals follow their variables, made
  with the global's value when missing, as FTE's `PR_AutoCvar`, for server, client and
  menu programs alike; `:serverinfo` and `:userinfo` variables are a server's info keys
  and its players'. `Server.exec_opts/1` brings a program up to date before each call.
- The console's variable commands as FTE's: `set` with the rest of the line as value
  and `//` description, `seta`, `setfl`, `set_tp`, `toggle name [a [b]]`, `inc`, a
  variable's name printing its value, default and latch, `cvarreset`, `vid_reload`,
  `vid_restart`; `exec` with FTE's rules (`config.cfg` superseded by an earlier
  `default.cfg`, `fte.cfg` after it, `cvar_lockdefaults` after `default.cfg`, `name.cfg`
  for `name`); `cfg_save`, `cfg_save_ifmodified`; aliases kept with the variables;
  unknown commands reported only while `cl_warncmd` is set; `Console.run/3` option
  `from: :server` for commands a server sends.
- Cvar builtins as FTE's: `cvar` makes a missing variable while `pr_autocreatecvars`
  is set and answers `pr_checkextension` and `halflifebsp`; `cvar_string` gives a
  latched value; `cvar_set` refuses `:notfromserver` variables; `registercvar` takes
  DarkPlaces flags; `cvar_type` gives FTE's bits; `cvar_defstring`,
  `cvar_description`, `buf_cvarlist` (517) and `cvars_haveunsaved`.
- `QuakeServer.Source` callback `depth/1`, where a file is in the search order.

### Changed

- `checkbuiltin` asks the program's own builtins module whether it knows a builtin.
- A server that ends (`QuakeServer.Runner`) no longer counts as running in the
  console variable table.
- `Server.cvar/2` reads a value as FTE's `Q_atof` (a 32-bit float); `Server.put_cvar/3`
  sets as FTE's `Cvar_Set` and writes a number as `Cvar_SetValue` does. A server's own
  table registers the engine variables; the defaults the server used to keep in itself
  are the engine list's. `Server.release/1` frees a table the server made itself.
- `exec` no longer looks under `cfg/` for a file it cannot find; `sets` and `setu` are
  gone, as FTE has neither.

### Fixed

- `ftos` writes a fraction as FTE's `Q_ftoa` (every significant digit of the 32-bit
  float, no padding) and `vtos` as `'%f %f %f'`; they wrote Quake's `%5.1f`, so a value
  such as 0.75 became `  0.8`, and the numbers FreeHL writes into cvars, info keys and
  save files lost their fractions. `pr_brokenfloatconvert` brings back `%5.1f` for
  `ftos`.
- `random` is FTE's: steps of 1/32768 offset by half a step (never 0 or 1), scaled by
  one argument or spanning two; it ignored its arguments and could return 0.
- `findradius` is FTE's: an optional field to chain through, entities with `solid` 0
  found when their flags hold `FL_FINDABLE_NONSOLID` (16384), and the cvars
  `sv_gameplayfix_blowupfallenzombies` and `sv_gameplayfix_findradiusdistancetobox`.
- `aim` is FTE's: off (straight along `v_forward`) while `sv_aim` is 1 or more, the
  shot from the shooter's `view_ofs` height rather than Quake's fixed 20 units, and
  teammates skipped under `teamplay`.
- `objerror` prints `Program error: ` with its arguments joined, removes `self` and stops
  every running function, as FTE's does; it went on running the caller.
- `breakpoint` prints `break statement` and `dprint` prints while `developer` is set,
  as FTE's do; both did nothing.
- `setmodel` sizes the entity by FTE's rule: always for a world submodel, for any model
  when the program is not a QuakeWorld one or `sv_gameplayfix_setmodelsize_qw` is set,
  and otherwise only for a found model that is not a Quake alias model.
- `MOVETYPE_FOLLOW` turns the follower's offset with its `punchangle` and the leader's
  angles scaled by `r_meshpitch` and `r_meshroll`, as FTE's `WPhys_Physics_Follow` does.
- The move types FTE runs that the server left still: 13 (`H2PUSHPULL`) moves as a
  pusher, 14 (`H2SWIM`) and 33 (`FLY_WORLDONLY`) as tossed things without gravity (33 as
  a walking player for the player), and 32 (`PHYSICS`) thinks and is relinked.
- Monster steps, walking and getting unstuck use FTE's step height
  (`QuakeServer.Physics.step_size/1`): `pm_stepheight`, 18 while it is empty.
- Coordinates in eighths and angles in 256ths of a turn are rounded half away from zero,
  as FTE's `MSG_ToCoord` and `MSG_WriteAngle8` write them; they were cut toward zero.
- `vectoangles` is FTE's (`QuakeServer.Angles.vectoangles/3`): angles keep their
  fractions of a degree, `up` gives the roll, and pitch and roll follow `r_meshpitch`
  and `r_meshroll`; it gave whole degrees, as Quake's does. With FTE's `sv_mintic` of 0
  a frame lasts a few milliseconds, and FreeHL's monsters turn less than a degree a
  frame, so a turn was lost to the whole degree each frame: Barney in c0a0e stopped
  halfway down the walkway once his heading was 5 degrees off his route, gave up the
  route there and played his door sequences on the spot. He now walks to the tram
  button and to the retina scanner and opens the doors there.
- Entity references in a file carried to the next level follow Half-Life's level
  transition rule (GoldSrc, the HLSDK's `CSaveRestoreBuffer`) instead of FreeHL's under
  FTE (`QuakeServer.EntityTable`): each written file keeps an entity table of its `{`
  `}` blocks (the entity that wrote each), carried with the written files (server option
  `:entity_tables`), and while the program reads a carried file `edict_num` gives the
  entity a block was restored into for an entity that was carried, keeps the world and
  player slots, and gives the world for any other number. FreeHL's c0a0a no longer has
  the tram's timer from c0a0 take over the entity of the narration's trigger: the tram
  gets a fresh timer, keeps moving, and `tride/c0a0_tr_dest.wav` plays.
- `externvalue`, `isfunction`, `callfunction` and function keys find `0:name` as FTE's
  `ED_FindFunction` does, so a level brought back keeps its entities' functions.
- Numbers in text are read as C reads them (`QuakeServer.TextNumbers`): `stof` and the
  other `atof` readings take `.3`, `-.5`, `+1`, hex and C white space, giving a 32-bit
  float; entity keys are read as FTE's `ED_ParseEpair` reads them (`strtod` for floats
  and each vector word, `strtol` base 0 for integer and entity fields). `.3` read as 0,
  so FreeHL's `c0a0` fired the `start_titles` trigger_auto (`delay .3`) at once and the
  tram left 0.3 seconds before FTE's.
- `stov` stops at the first word that is not a number and at a closing `'`, as FTE's
  `PF_stov`.
- `getentityfieldstring` is FTE's: values as `PR_UglyValueString` writes them (functions as
  `0:name`) and FTE's left-out fields; function keys read `0:name` as FTE does.
- New entities get `drawflags` 96, as FTE spawns them.
- `checkpvs` (240) decides as FTE's `PF_checkpvs`: from the leaves recorded when the
  entity was last linked, not its box as it stands; an entity never linked is not seen,
  one in more than 32 leaves always is (`QuakeServer.Visibility.in_pvs?/3`). FreeHL's
  level change from `c0a0` to `c0a0a` now carries the four `scripted_sequence`s and the
  train, as under FTE, instead of sixteen `path_track`s.
- `QuakeServer.Visibility.pvs/2` takes a point on a node's plane to the back side, as
  FTE's `ClusterForPoint` does.
- `Server.start/2` runs FTE's `SV_SpawnServer` steps in its order: the info keys
  `mapname`, `*cheats`, `*bspversion` and `*startspot` before the program loads (an empty
  one removed, not kept empty); `init(-1)` at time 0 on fresh memory, before the model
  list and the world entity; the world's box (`mins`, `maxs`, `absmin`, `absmax`); the
  player slots' entities allocated from the start; `time` 1, and `coop` or `deathmatch`
  from their cvars, before `initents`; the world's angles cleared and the level's name
  taken from its `message` (`ext.levelname`) after spawning; the `map` key set after the
  settle frames. Option `:serverinfo` carries the server's info keys from level to level,
  as FTE's server info lasts.
- `Server.connect/3` is FTE's `SV_SetUpClientEdict` and `SV_Begin_Core`: the player gets
  its name from its info keys (`Player` by default), `clientcolors`, `gravity`,
  `maxspeed`, `movetype` noclip and no frags; `ClientConnect` is given 1 for a client
  running a client program (option `csqc: true`); `oldorigin` follows `origin`; a
  program running its players' commands runs one empty command; `parm_string` is set
  and carried with the spawn parameters. A NetQuake program's player entity is not
  cleared on connecting but on leaving.
- `Server.save_spawn_parms/1` is FTE's `SV_SaveSpawnparms`: the player's parameters go
  back into the globals before `SetChangeParms`, and `parm_string` and `serverflags` are
  carried (`serverflags` was not carried by the runner). `change_parms/1` uses it.
- `Server.disconnect/1`: FTE's `SV_DespawnClient`, run (`ClientDisconnect`) on a level
  kept for its landmark, as FTE's `SV_SaveLevelCache` does.
- A level left through a landmark is kept as FTE's level cache keeps it: a program with
  `SV_PerformSave` and `SV_PerformLoad` (FreeHL) has the level saved in FTE's format
  (`Server.save_level/1`, after `ClientDisconnect`) and, on a return, started afresh with
  the save's console variables and restored by the program (`Server.load_level/2`, the
  world relinked and the saved time taken up); the level was kept in memory as it stood
  and the program's own save and restore never ran. `Store.open_buffer/4`,
  `Store.open_output/3` and `Store.output/3` hand the program FTE's engine files.
  Another program's level is still kept as it stands; `Server.resume/2` brings it back as
  `SV_LoadLevelCache` does: the star keys again, the server's current info keys under the
  level's, `serverflags` and `time`.
- The runner follows FTE's listen server: a level starts without the player and stays
  paused (the clock held at 1.5) until its client begins (`Runner.begin/3`, after the
  client sent `{:serverdata, …}` has loaded); the view set on beginning is the player's
  `angles` under `fixangle`, else `v_angle`, with roll. A level change sends the
  reliable messages still queued as a last packet before `{:changing, map}`, and
  carries the player's info keys. Its levels share one console variable table (the
  `:cvar_table` option, or one of its own) instead of replaying the console commands
  given before into each new level, which repeated a `changelevel` typed at the console
  forever. The client's server info comes in the serverdata
  (FTE's `fullserverinfo`, without `mapname`) instead of a stuffed command in the first
  packet.
- `QuakeServer.Signon`: static entities (`makestatic`), static sounds (`ambientsound`)
  and the player's info keys are sent to the client before it begins, as FTE's
  `svc_spawnstatic`, `svc_spawnstaticsound` and `svc_updateuserinfo`; they were kept on
  the server and never sent.

- Players are sent the server's sound list and particle effect list, and what is added
  to them later (`QuakeServer.Precaches`, from `QuakeServer.Network.frame/2`), as FTE's
  signon and delayed precaches send them.
- `pointparticles` and `trailparticles` go to the players that may hear them as FTE's
  `svcfte_pointparticles`, `svcfte_pointparticles1` and `svcfte_trailparticles`, besides
  the server's events.
- `getsoundindex` adds a sound not on the list unless asked only to look it up.
- `QuakeServer.Builtins.Write.coord/2` and `coords/2`: coordinates as `WriteCoord`
  writes them.
- `serverkey` joins its arguments, gives null for an empty value, and answers FTE's
  engine keys (`Settings.server_key/2`).
- A level change sends the client `{:changing, map}` first.
- Sounds start as FTE starts them (`QuakeServer.Sounds`): a sound message in the players'
  packets, reliable for brush entities, to everyone when reliable or unattenuated, to
  the players that may hear it otherwise; `sound` takes FTE's pitch, flags and offset
  arguments and a QuakeWorld program's reliable channel bit; `pointsound` too.
- Changes to the server's info keys reach the players (`svc_serverinfo`), and each level
  starts by sending them all (`fullserverinfo`).
- Light style colours reach the client with the styles.
- A server-side pose takes all five bone controllers and both sub-blends as floats.
- The console's `sky name` sets the sky drawn.
- `QuakeServer.Runner` pushes each packet to its subscribed client (`subscribe/2`) and
  hands events, the player's eye and view angles over in a table (`handoff/1`,
  `take/1`), so neither the client nor the game waits on a busy server.
- `processmodelevents` is FTE's: a looping sequence's events come round every cycle,
  events fire from the base time up to but not including the target, and nothing fires
  when the two are equal.
- Entity delivery is FTE's: `SendFlags` are kept every server frame and cleared after,
  updates go out with each packet a player is sent, entities never sent or sent back
  into sight get every bit, `PVSF_NOREMOVE` keeps an entity on the client, and the
  player may see what FTE's `SV_Snapshot_BuildQ1` lets through: the fat PVS (leaves
  within 8 units of the eye), leaves recorded when an entity is linked, `PVSF_USEPHS`
  never culled on Half-Life maps or without a PHS, `EF_NODEPTHTEST`, `tag_entity`
  roots, `viewmodelforclient`, `customizeentityforclient`, `nodrawtoclient`,
  `drawonlytoclient` and dimensions.
- `multicast` reaches only the players FTE sends to (PVS, PHS within 1024 units or by
  the PHS, `msg_entity`, `dimension_send`), reliably or in the datagram, and a packet
  carries the reliable messages before the entity updates and the datagram after.
- `bprint` and `sprint` read a QuakeWorld program's print level before the text, join
  every text argument, and reach the player as `svc_print`; `centerprint` keeps the last
  one for the next packet.
- Entities spawn with `dimension_see`, `dimension_seen`, `dimension_solid` and
  `dimension_hit` at `dimension_default` (255), and `Version` and `uniquespawnid` set;
  `dimension_send` starts at `dimension_default`.
- Freeing an entity clears `pvsflags` and `SendEntity` (and `classname` for a QuakeWorld
  program) and is refused for the world, a player or an entity already free.
- Every brush model is traced with the hull FTE chooses (`World.choose_hull/2`, the
  default `:hull`).
- `route_calculate` is FTE's: the waypoints are read once a level, the start and end
  waypoints are those whose radius holds the point or that it can see through the world,
  the node list ends with the entity's place and starts with the destination flagged
  `LF_DESTINATION`, a route with no path still gives the destination and the start, and
  the callback runs at the start of the next frame.
- A trace that starts inside one entity is still stopped by the next thing in its way,
  as FTE combines its traces; it was taken whole from the entity it started in.
- A pusher tests what it carries as if it were not solid by setting `solid` and putting
  it back, as FTE does, and an entity it nudges moves an eighth of a unit once.
- A tossed, bouncing or flying entity on the ground keeps what its think did.
- `tokenize` finds the end of a word without testing each character against a list.
- An entity's `solid` is read when it is traced or touched, not when it was last linked.
- All 64 spawn parameters are carried between levels, each in its own place.
- `fopen` of a name without `data/` reads `data/name` first, then `name`.
- `externvalue` and `externset` take program numbers 0 to -3 and names spread over
  several arguments, return vectors whole, and `&name` gives a global's address.
- `World.stuck?` counts `allsolid` and tests non-solid and trigger entities against brush
  models only.

