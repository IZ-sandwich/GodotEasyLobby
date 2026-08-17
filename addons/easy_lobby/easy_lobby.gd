## Autoloaded as "EasyLobby"
extends Node

## Code-based peer-to-peer multiplayer lobbies.
##
## Host a lobby to get a short join code, share it, and other players join with it.
## No port forwarding required and no global game server beyond a single self-hosted noray for introductions.
##
## The host is peer 1 and owns the roster; clients hold replicated copies.

# --- Signals ------------------------------------------------------------------

## The local player is now hosting. [param code] is the join code to share.
## The code has already been screened by [EasyLobbyCodeFilter].
signal lobby_created(code: String)

## The local player joined a lobby and the roster has arrived.
## Also emitted for the host when hosting a lobby.
signal lobby_joined(code: String)

## Joining failed. [param reason] is one of the JOIN_* constants.
signal lobby_join_failed(reason: String)

## A player entered the lobby.
signal player_joined(player: EasyLobbyPlayer)

## A player left the lobby.
signal player_left(peer_id: int)

## The roster, ready flags or lobby metadata changed.
signal lobby_updated()

## The lobby ended. [param reason] is one of the CLOSED_* constants.
signal lobby_closed(reason: String)

## Connection progress, for "connecting..." UI. See the STAGE_* constants on
## [EasyLobbyNorayConnection].
signal connect_progress(stage: String)

# --- Constants ----------------------------------------------------------------

const JOIN_BAD_CODE := "bad_code"
const JOIN_NORAY_SERVER_UNREACHABLE := "noray_server_unreachable"
const JOIN_NOT_FOUND := "not_found"
const JOIN_UNREACHABLE := "unreachable"
const JOIN_FULL := "full"
const JOIN_SEALED := "sealed"

const CLOSED_HOST_LEFT := "host_left"
const CLOSED_KICKED := "kicked"
const CLOSED_LEFT := "left"

## Join code alphabet. Must match NORAY_OID_CHARSET on the server. Excludes I, L,
## O and digits so codes survive being read aloud or copied off a screen.
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ"

## How many times to redraw a code that [EasyLobbyCodeFilter] rejects before
## giving up and using it anyway. Roughly one code in 250 is rejected, so
## needing even two draws is already unusual.
const MAX_CODE_DRAWS := 3

## How long the host waits for a peer to act on a [method _kicked] or
## [method _reject] notice before closing the socket from this end.
const DISCONNECT_GRACE_SEC := 2.0

# --- State --------------------------------------------------------------------

## The current join code, empty when not in a lobby.
var code: String = ""

## Whether the local player hosts this lobby.
var is_host: bool = false

## Host-set lobby metadata, replicated to everyone.
var meta: Dictionary = {}

## Whether the lobby is refusing new joins.
var sealed: bool = false

## Mapping from peer_id to EasyLobbyPlayer
var _players: Dictionary = {}  
var _max_players: int = 8
var _local_name: String = ""
var _busy: bool = false
var _noray: EasyLobbyNorayConnection


func _ready() -> void:
	_noray = EasyLobbyNorayConnection.new()
	_noray.name = "NorayConnection"
	_noray.stage_changed.connect(func(stage: String) -> void: connect_progress.emit(stage))
	add_child(_noray)

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# --- Public API ---------------------------------------------------------------


## Host a new lobby. On success [signal lobby_created] carries the join code.
##
## With [param offline] the lobby lives entirely on the local network. Only players
## on this subnet can join it, and the code is drawn locally rather than being a noray OID.
func create_lobby(player_name: String, max_players: int = 0, offline := false) -> Error:
	if _busy or is_in_lobby():
		return ERR_ALREADY_IN_USE
	_busy = true

	_local_name = player_name
	_max_players = max_players if max_players > 0 else _get_setting("easy_lobby/lobby/max_players", 8)
	_configure_noray()

	# max_players counts everyone; ENet's limit is the number of clients.
	var err: Error
	if offline:
		err = await _noray.host_lan_lobby(_make_local_code(), _max_players - 1)
	else:
		err = await _draw_acceptable_code()
		if err == OK:
			err = await _noray.host_lobby(_max_players - 1)

	if err != OK:
		_busy = false
		return err

	is_host = true
	sealed = false
	meta = {}
	code = _noray.get_code()

	var host_player := EasyLobbyPlayer.new()
	host_player.peer_id = 1
	host_player.player_name = player_name
	_players = {1: host_player}

	_busy = false
	lobby_created.emit(code)
	player_joined.emit(host_player)
	lobby_updated.emit()
	return OK


## Join a lobby by code. On success [signal lobby_joined] fires once the roster
## has arrived; on failure [signal lobby_join_failed] carries a JOIN_* reason.
##
## [param offline] looks for the lobby on the local network only, skipping noray
## entirely. It has to match how the host started the lobby.
func join_lobby(join_code: String, player_name: String, offline := false) -> Error:
	if _busy or is_in_lobby():
		return ERR_ALREADY_IN_USE

	var normalized := normalize_code(join_code)
	if not is_valid_code(normalized):
		lobby_join_failed.emit(JOIN_BAD_CODE)
		return ERR_INVALID_PARAMETER

	_busy = true
	_local_name = player_name
	_configure_noray()

	var err := OK as Error
	if not offline:
		err = await _noray.register(
			_get_setting("easy_lobby/noray/host", "127.0.0.1"),
			_get_setting("easy_lobby/noray/port", 8890),
			_get_setting("easy_lobby/noray/registrar_port", 8809),
		)
		if err != OK:
			_busy = false
			lobby_join_failed.emit(JOIN_NORAY_SERVER_UNREACHABLE)
			return err

	err = await _noray.join_lobby(normalized, offline)
	if err != OK:
		_noray.teardown()
		_busy = false
		lobby_join_failed.emit(
			JOIN_NOT_FOUND if err == ERR_DOES_NOT_EXIST else JOIN_UNREACHABLE
		)
		return err

	is_host = false
	code = normalized
	_busy = false

	# The host decides whether we are actually allowed in; lobby_joined waits
	# for the roster it sends back. 
	# Expect either a "_sync_lobby" or "_reject" rpc as a response
	_request_join.rpc_id(1, player_name)
	return OK


## Leave the lobby, or shut it down if hosting.
func leave_lobby() -> void:
	if not is_in_lobby():
		return
	_noray.teardown()
	_reset()
	lobby_closed.emit(CLOSED_LEFT)


## Host only: stop accepting new players.
func seal_lobby(is_sealed: bool = true) -> void:
	if not is_host:
		return
	sealed = is_sealed
	_sync_lobby.rpc(_roster_payload(), meta, sealed)


## Host only: remove a player.
func kick(peer_id: int) -> void:
	if not is_host or peer_id == 1 or not _players.has(peer_id):
		return
	_kicked.rpc_id(peer_id)
	await _disconnect_after_grace(peer_id)


## Set the local player's ready flag.
func set_ready(value: bool) -> void:
	if not is_in_lobby():
		return
	if is_host:
		_apply_ready(1, value)
	else:
		_request_ready.rpc_id(1, value)


## Host only: set a replicated lobby-wide value (e.g. map, mode, difficulty, etc).
func set_lobby_meta(key: String, value: Variant) -> void:
	if not is_host:
		return
	meta[key] = value
	_sync_lobby.rpc(_roster_payload(), meta, sealed)


func is_in_lobby() -> bool:
	return not code.is_empty()


## The roster, ordered by peer id so the host is always first.
func get_players() -> Array[EasyLobbyPlayer]:
	var ids := _players.keys()
	ids.sort()
	var out: Array[EasyLobbyPlayer] = []
	for id in ids:
		out.append(_players[id])
	return out


func get_player(peer_id: int) -> EasyLobbyPlayer:
	return _players.get(peer_id)


func get_local_player() -> EasyLobbyPlayer:
	return _players.get(multiplayer.get_unique_id() if is_in_lobby() else 0)


## Whether every player has readied up, and there is more than one of them.
func all_ready() -> bool:
	if _players.size() < 2:
		return false
	return _players.values().all(func(p: EasyLobbyPlayer) -> bool: return p.is_ready)


## Tidy up a typed code: strip spaces, dashes, and uppercase it.
static func normalize_code(raw: String) -> String:
	return raw.strip_edges().replace(" ", "").replace("-", "").to_upper()


## Whether [param candidate] could be a real join code.
##
## Length matters as much as the alphabet: without it, anything spelled from the
## alphabet ("ASDF") passes and gets sent to noray as a genuine lookup, wasting a
## round trip and reporting "no such lobby" instead of "that isn't a code".
##
## Set easy_lobby/lobby/code_length to 0 to skip the length check, which is what
## word-style OIDs (NORAY_ENABLE_WORDS_OID) need, since those vary in length.
static func is_valid_code(candidate: String) -> bool:
	if candidate.is_empty():
		return false

	var expected_length := int(ProjectSettings.get_setting("easy_lobby/lobby/code_length", 6))
	if expected_length > 0 and candidate.length() != expected_length:
		return false

	for character in candidate:
		if not CODE_ALPHABET.contains(character):
			return false
	return true


# --- RPCs ---------------------------------------------------------------------
# Client -> host requests are "any_peer"; the host validates everything and is
# the only thing that ever writes to the authoritative roster.


@rpc("any_peer", "call_remote", "reliable")
func _request_join(player_name: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()

	if sealed:
		_reject_join(sender, JOIN_SEALED)
		return
	if _players.size() >= _max_players:
		_reject_join(sender, JOIN_FULL)
		return

	var player := EasyLobbyPlayer.new()
	player.peer_id = sender
	player.player_name = player_name
	_players[sender] = player

	_sync_lobby.rpc(_roster_payload(), meta, sealed)
	player_joined.emit(player)
	lobby_updated.emit()


@rpc("any_peer", "call_remote", "reliable")
func _request_ready(value: bool) -> void:
	if not is_host:
		return
	_apply_ready(multiplayer.get_remote_sender_id(), value)


@rpc("authority", "call_remote", "reliable")
func _sync_lobby(roster: Array, lobby_meta: Dictionary, is_sealed: bool) -> void:
	var was_empty := _players.is_empty()

	var previous := _players.keys()
	_rebuild_roster(roster)
	meta = lobby_meta
	sealed = is_sealed

	for id in _players:
		if not previous.has(id):
			player_joined.emit(_players[id])
	for id in previous:
		if not _players.has(id):
			player_left.emit(id)

	if was_empty:
		lobby_joined.emit(code)
	lobby_updated.emit()


@rpc("authority", "call_remote", "reliable")
func _reject(reason: String) -> void:
	_noray.teardown()
	_reset()
	lobby_join_failed.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _kicked() -> void:
	_noray.teardown()
	_reset()
	lobby_closed.emit(CLOSED_KICKED)


# --- Internals ----------------------------------------------------------------


## Register with noray, redrawing a few times if the code it returns is bad.
##
## Redrawing is only free here, before [method EasyLobbyNorayConnection.host_lobby]
## has stood up the ENet server.
func _draw_acceptable_code() -> Error:
	var noray_host: String = _get_setting("easy_lobby/noray/host", "127.0.0.1")
	var noray_port: int = _get_setting("easy_lobby/noray/port", 8890)
	var registrar_port: int = _get_setting("easy_lobby/noray/registrar_port", 8809)

	for attempt in MAX_CODE_DRAWS:
		# The first attempt may reuse an existing registration. Retries must
		# force a fresh identity, since that is the whole point of a redraw.
		var err: Error = await _noray.register(
			noray_host, noray_port, registrar_port, attempt > 0
		)
		if err != OK:
			return err
		if not EasyLobbyCodeFilter.is_offensive(_noray.get_code()):
			return OK

	# Out of draws. Hosting with an awkward code beats refusing to host at all.
	push_warning(
		"EasyLobby: no clean code in %d draws; proceeding with '%s'."
		% [MAX_CODE_DRAWS, _noray.get_code()]
	)
	return OK


func _make_local_code() -> String:
	var length := int(_get_setting("easy_lobby/lobby/code_length", 6))
	if length <= 0:
		length = 6

	var drawn := ""
	for attempt in MAX_CODE_DRAWS:
		drawn = ""
		for i in length:
			drawn += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
		if not EasyLobbyCodeFilter.is_offensive(drawn):
			return drawn

	push_warning(
		"EasyLobby: no clean code in %d draws; proceeding with '%s'."
		% [MAX_CODE_DRAWS, drawn]
	)
	return drawn


func _configure_noray() -> void:
	_noray.configure(
		_get_setting("easy_lobby/timeouts/handshake_sec", 8.0),
		_get_setting("easy_lobby/timeouts/register_retries", 3),
		_get_setting("easy_lobby/debug/verbose_logging", false),
		_get_setting("easy_lobby/lan/enabled", true),
		_get_setting("easy_lobby/lan/discovery_port", 8898),
		_get_setting("easy_lobby/lan/discovery_timeout_sec", 0.6),
		_get_setting("easy_lobby/timeouts/noray_connect_sec", 5.0),
	)


func _reject_join(peer_id: int, reason: String) -> void:
	_reject.rpc_id(peer_id, reason)
	await _disconnect_after_grace(peer_id)


## Notify a peer to close connection or close anyway after timeout.
func _disconnect_after_grace(peer_id: int) -> void:
	var deadline := Time.get_ticks_msec() + int(DISCONNECT_GRACE_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		# The lobby can be shut down under us while we wait.
		if not is_host or multiplayer.multiplayer_peer == null:
			return
		if not multiplayer.get_peers().has(peer_id):
			return  # they took the hint and closed from their end

	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(peer_id)


func _apply_ready(peer_id: int, value: bool) -> void:
	var player: EasyLobbyPlayer = _players.get(peer_id)
	if player == null or player.is_ready == value:
		return
	player.is_ready = value
	_sync_lobby.rpc(_roster_payload(), meta, sealed)
	lobby_updated.emit()


func _roster_payload() -> Array:
	return _players.values().map(func(p: EasyLobbyPlayer) -> Dictionary: return p.to_dict())


## Rebuild from a replicated payload for players we already knew about.
func _rebuild_roster(roster: Array) -> void:
	var rebuilt := {}
	for entry in roster:
		var player := EasyLobbyPlayer.from_dict(entry)
		var existing: EasyLobbyPlayer = _players.get(player.peer_id)
		# Copy over local settings for existing players here if needed
		rebuilt[player.peer_id] = player
	_players = rebuilt


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host or not _players.has(peer_id):
		return
	_players.erase(peer_id)
	_sync_lobby.rpc(_roster_payload(), meta, sealed)
	player_left.emit(peer_id)
	lobby_updated.emit()


func _on_server_disconnected() -> void:
	if not is_in_lobby() or is_host:
		return
	_noray.teardown()
	_reset()
	lobby_closed.emit(CLOSED_HOST_LEFT)


func _reset() -> void:
	code = ""
	is_host = false
	sealed = false
	meta = {}
	_players = {}
	_busy = false


func _get_setting(key: String, fallback: Variant) -> Variant:
	return ProjectSettings.get_setting(key, fallback)
