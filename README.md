# EasyLobby

Code-based peer-to-peer multiplayer for Godot 4. Host a lobby, get a 6-character
join code, share it. No port forwarding, and no game server - the only
infrastructure required is one small [noray](https://github.com/foxssake/noray) instance
that introduces peers and relays for the minority who can't connect directly.
Players on the same network find each other by broadcast and skip noray
or skip noray altogether by using a [LAN-only lobby](#lan-only-lobbies). Also optionally VoIP can be enabled in the lobby.

Once peers are connected, noray is out of the data path entirely.

```gdscript
# Host
await EasyLobby.create_lobby("Player 1")
# get signal lobby_created("CNKBRH")

# Join
await EasyLobby.join_lobby("CNKBRH", "Player 2")
# get signal lobby_joined("CNKBRH")
```

After that it's ordinary Godot multiplayer: `@rpc`, `MultiplayerSpawner`,
`MultiplayerSynchronizer`. The host is peer 1.


## Setup

1. Install the addons and enable them in this order: netfox.internals, netfox.noray, EasyLobby.
2. (Optional) Install [TwoVoip](https://github.com/goatchurchprime/two-voip-godot-4) addon and GDExtension if you want VoIP.
3. Stand up noray - see [`deploy/`](../../deploy/README.md).
4. Point the game at the noray host: **Project Settings -> Easy Lobby -> Noray -> Host**.

## Trying it out

Check out the demo scene `demo/main.tscn`. Run two or more copies (In top bar of godot: Debug -> Run Multiple Instances), host in one, paste the code into the other.

The "Connection" dropdown picks which path gets used, both instances should use the same mode.

| Mode | What it exercises | Needs noray |
| --- | --- | --- |
| Auto (LAN, then noray) | The full ladder, stopping at the first that works (LAN -> punchthrough -> relay) | Yes |
| noray only | Punchthrough -> relay, with the LAN shortcut suppressed | Yes |
| Relay only (testing only) | The relay, with LAN and punchthrough both suppressed | Yes |
| LAN only (offline) | Broadcast discovery and a direct connection | No |

The status line names the path that won - `connected via LAN`, `connected via punch`, or `connected via relay`

## API

All of it is on the `EasyLobby` autoload.

| Method | Notes |
| --- | --- |
| `create_lobby(name, max_players = 0, offline = false)` | `await`. 0 uses the project setting. `offline` is LAN-only. |
| `join_lobby(code, name, offline = false)` | `await`. Code is normalised and validated first. |
| `leave_lobby()` | Shuts down the lobby if hosting. |
| `seal_lobby(sealed = true)` | Host only. Seals the lobby refusing new players to join even if not full. |
| `kick(peer_id)` | Host only. Kicks a player. |
| `set_ready(bool)` | Any player. |
| `set_lobby_meta(key, value)` | Host only. Replicated to everyone. |
| `send_chat(text)` | Any player. Blank messages are dropped. |
| `get_chat_messages()` -> `Array[Dictionary]` | Oldest first, at most 100. |
| `get_players()` -> `Array[EasyLobbyPlayer]` | Ordered by peer id, host first. |
| `get_local_player()` / `get_player(id)` | |
| `all_ready()` | True when everyone is ready and there are >= 2 players. |
| `is_in_lobby()` | |
| `get_game_id()` | What this build calls itself in the handshake. |

| Signal | Fires when |
| --- | --- |
| `lobby_created(code)` | Hosting started, or the code was rerolled. |
| `lobby_joined(code)` | Joined and the roster arrived. |
| `lobby_join_failed(reason)` | One of the `JOIN_*` constants. |
| `player_joined(player)` / `player_left(peer_id)` | |
| `lobby_updated()` | Fires when player roster, ready flags or metadata have changed. |
| `chat_message_received(message)` | A chat message arrived, the local player's included. |
| `lobby_closed(reason)` | One of the `CLOSED_*` constants. |
| `connect_progress(stage)` | `registering` / `searching LAN` / `punching` / `relaying` / `connected via ...`. |

Failure reasons are constants:
`JOIN_BAD_CODE`, `JOIN_NO_SERVER`, `JOIN_NOT_FOUND`, `JOIN_UNREACHABLE`,
`JOIN_FULL`, `JOIN_SEALED`, `JOIN_WRONG_GAME_ID`, `CLOSED_HOST_LEFT`,
`CLOSED_KICKED`, `CLOSED_LEFT`.

`EasyLobbyPlayer` carries `peer_id`, `player_name`, `is_ready` and `custom`,
which replicate on update.

## Voice chat (optional)

Opus voice over the same connection, on `EasyLobby.voice`. It needs the
[TwoVoip](https://github.com/goatchurchprime/two-voip-godot-4) GDExtension
(v5+, Godot 4.6+) installed at `addons/twovoip/`. Easy lobby can work fine without it.

It also needs **Project Settings -> Audio -> Driver -> Enable Input** on.

### Cost

An Opus stream is roughly 3-5 KB/s including packet overhead. Voice is broadcast and would be ~200 KB/s in a full 8-player lobby at worst case of everyone speaking. Voice activation means that the worst case is rare but a relayed host could start being throttled by noray `NORAY_UDP_RELAY_MAX_INDIVIDUAL_TRAFFIC` (default `128kb`, bytes/sec). That throttle hits the game traffic sharing the connection with voice. Test with your game and raise the cap if necessary.

### Known limitations

- No echo cancellation - RNNoise removes background noise, not sound from other
  players coming back in through your own microphone. Headphones, or push-to-talk.
- TwoVoip is a GDExtension, so it has to be installed per platform and is the reason voip is optional.

# How it works

noray maps an identifier to a host address in order to do its job, so EasyLobby just configures that identifier to be short to work as the "join code":

```env
NORAY_OID_LENGTH=6
NORAY_OID_CHARSET=ABCDEFGHJKMNPQRSTUVWXYZ
```

These two configs must stay in sync with the noray server:

| Addon | Server |
| --- | --- |
| `CODE_ALPHABET` in `easy_lobby.gd` | `NORAY_OID_CHARSET` |
| `easy_lobby/lobby/code_length` | `NORAY_OID_LENGTH` |

The default alphabet excludes `I`, `L`, `O` and digits so codes can be easily read outloud.


## The connection ladder

In auto mode, `join_lobby()` tries three paths in order and stops at the first that works:

| Path | How |
| --- | --- |
| **LAN** | Clients send UDP broadcasts on the local subnet, host responds on a discovery port (configured in project settings: `easy_lobby/lan/discovery_port`) |
| **Punchthrough** | noray introduces both peers, they punch out through their NATs |
| **Relay** | noray forwards every packet |

Discovery costs `easy_lobby/lan/discovery_timeout_sec` on every join that turns
out not to be on the LAN, so the default is deliberately short (0.6s). LAN mode can be turned off completely in project settings at `easy_lobby/lan/enabled`.


## LAN-only lobbies

Pass the `offline` flag for a lobby to not use noray:

```gdscript
# Host - no noray, no internet, no registration.
await EasyLobby.create_lobby("Player 1", 0, true)

# Join - broadcasts for the code and connects to whoever answers.
await EasyLobby.join_lobby("CNKBRH", "Player 2", true)
```

The code is generated locally from `CODE_ALPHABET`, screened by
  `EasyLobbyCodeFilter` exactly like the noray path.

Everything past the connection is identical: same roster, same RPCs, same
signals, host is still peer 1.

## Offensive codes

Random six-letter codes occasionally spell something you would rather not put on
a player's screen. `EasyLobbyCodeFilter` screens each drawn code, and
`create_lobby()` redraws up to `MAX_CODE_DRAWS` times until one passes. Measured
reject rate is 0.4%, roughly one lobby in 250 costs an extra round trip to
noray.

Add your own terms (three characters or more) in
`easy_lobby/lobby/extra_blocked_terms`.

## Knowing whether the join code is still valid

A code is only good while a TCP session with noray is alive, noray
drops a host from its repository the moment that socket closes. There is no remote-close detection. Also, `_oid`, `_pid` and `_local_port` are never cleared, `Noray.oid` keeps a code even if a connection to noray ended.

None of this applies to a LAN-only lobby - there's no noray session to lose, so
its code is good for exactly as long as it's still hosting.

So treat a join code as a lease on a TCP session. A
host whose lobby has sat idle may find their code has quietly stopped resolving, the fix for which is to call `reroll_code()` and let the players reconnect if they got dropped.

## Known limitations

- **No host migration.** If peer 1 leaves, the session ends - you get
  `lobby_closed("host_left")`.
- **UDP only.** noray relays UDP and has no TCP or TLS/443 path, so players on
  networks that block UDP outright cannot connect at all. There is no workaround
  within this architecture.
- **The host is authoritative and can cheat.** Inherent to hosted P2P.
- **Peers see each other's IPs** on the direct path. Unavoidable without
  relaying everything, and a relay-only mode wouldn't actually prevent it -
  noray answers `connect <oid>` with the host's address to anyone who asks.

## Notes on netfox.noray

### Invalid join codes

`noray.gd` does not check for error replies. When an OID is unknown, noray
answers `connect` / `connect-relay` with an error payload, which netfox emits as `on_connect_nat("\"Error", 0)` - a bogus
address. Left alone that wastes a full handshake timeout on both the
punchthrough and relay legs, then reports "unreachable" for what is really "no such lobby".

`noray_connection.gd` watches the raw `on_command` signal to catch this, so a
bad code fails in about a second with `JOIN_NOT_FOUND`.

### Checking for connection to noray

A noray server that is down or unreachable hangs the caller forever
instead of failing it. `noray_connection.gd` checks the port itself first, on its own timeout
(`easy_lobby/timeouts/noray_connect_sec`, default 5s), and only hands off to
netfox once something has answered. Hosting then fails with `ERR_CANT_CONNECT`
and joining with `JOIN_NORAY_SERVER_UNREACHABLE`.

A noray shutdown or internet drop that happens between the check and the connect can still hang, but that is much less likely to happen than.
