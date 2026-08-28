class_name EasyLobbyNorayConnection
extends Node

## Transport layer: noray registration, plus the LAN -> punchthrough -> relay ladder.
##
## Also serves LAN-only lobbies which do not use noray
## [method host_lan_lobby] and the offline flag on [method join_lobby].
##
## Deliberately knows nothing about lobbies, rosters or players. Its only job is
## to end up with a working [ENetMultiplayerPeer] on [member Node.multiplayer].

signal stage_changed(stage: String)

const STAGE_REGISTERING := "registering"
const STAGE_SEARCHING_LAN := "searching LAN"
const STAGE_PUNCHING := "punching"
const STAGE_RELAYING := "relaying"
const STAGE_CONNECTED_AS_HOST := "connected as host"
const STAGE_CONNECTED_VIA_LAN := "connected via LAN"
const STAGE_CONNECTED_VIA_PUNCH := "connected via punch"
const STAGE_CONNECTED_VIA_RELAY := "connected via relay"

## How long the LAN path waits on ENet after discovery has already answered.
##
## Short on purpose: an answered probe proves the host is up and one hop away, so
## this only has to cover ENet's own handshake. Its real job is to cap the cost of
## the odd case where the discovery port is open but the game port is firewalled,
## since every second spent here delays the punchthrough path.
const LAN_CONNECT_TIMEOUT_SEC := 2.0

## How long a LAN-only join spends looking before giving up.
const LAN_ONLY_SEARCH_TIMEOUT_SEC := 3.0

var verbose_logging := false

var _handshake_timeout: float = 8.0
var _noray_connect_timeout: float = 5.0
var _register_retries: int = 3
var _is_hosting := false
var _connect_error := ""

var _lan: EasyLobbyLanDiscovery
var _lan_enabled := true
var _lan_discovery_port := 8898
var _lan_timeout := 0.6

# Testing aid: take the relay rung and nothing else. See configure().
var _force_relay := false

var _game_id := ""

# Set only while hosting a LAN-only lobby, where there is no OID to read the code
# back out of. Doubles as the "this lobby has no noray behind it" flag.
var _lan_code := ""

# address:port -> true, for handshakes currently in flight. See _open_mapping().
var _open_mappings := {}


# Remembered so a port collision can re-register without the caller re-supplying
# them. See _ensure_bindable_port().
var _noray_host := ""
var _noray_port := 0
var _registrar_port := 0


# Built here rather than in _ready() so configure() and teardown() can use these parameters.
func _init() -> void:
	_lan = EasyLobbyLanDiscovery.new()
	_lan.name = "LanDiscovery"


func _ready() -> void:
	add_child(_lan)


## [param force_relay] is a testing aid: it holds the LAN and punchthrough rungs
## shut so every noray join goes over the relay. It costs bandwidth on
## the noray box and latency for the players, so it is not something to ship on.
## The [param offline] flag on [method join_lobby] still wins over it.
func configure(
	handshake_timeout: float,
	register_retries: int,
	log_verbose := false,
	lan_enabled := true,
	lan_discovery_port := 8898,
	lan_timeout := 0.6,
	noray_connect_timeout := 5.0,
	game_id := "",
	force_relay := false
) -> void:
	_handshake_timeout = handshake_timeout
	_register_retries = maxi(1, register_retries)
	verbose_logging = log_verbose
	_lan_enabled = lan_enabled
	_lan_discovery_port = lan_discovery_port
	_lan_timeout = lan_timeout
	_noray_connect_timeout = noray_connect_timeout
	_game_id = game_id
	_force_relay = force_relay
	_lan.verbose_logging = log_verbose


## The join code for this peer, valid once [method register] or
## [method host_lan_lobby] has succeeded.
func get_code() -> String:
	return _lan_code if not _lan_code.is_empty() else Noray.oid


## Whether we still hold a usable registration with noray.
##
## The noray session is allowed to drop. Nothing reconnects it behind our back --
## netfox has no auto-reconnect, and only [method register] ever calls
## connect_to_host, so a closed socket is a sufficient signal that the next
## call must register afresh.
func is_session_valid() -> bool:
	# A LAN-only lobby has no noray session to lose. Its code is good for exactly
	# as long as we are still hosting and answering probes.
	if not _lan_code.is_empty():
		return _is_hosting
	return _is_registered()


## Connect to noray and claim an OID/PID plus a registered public address.
##
## noray generates OIDs without checking uniqueness, but its repository rejects
## duplicates by throwing, so on a collision the host is never sent `set-oid`
## and this simply times out. Retrying draws a fresh OID, which is the fix.
func register(
	host: String, port: int, registrar_port: int, force_new_identity := false
) -> Error:
	stage_changed.emit(STAGE_REGISTERING)
	_noray_host = host
	_noray_port = port
	_registrar_port = registrar_port

	if not force_new_identity and _is_registered():
		return OK

	if not Noray.is_connected_to_host():
		if not await _can_reach(host, port, _noray_connect_timeout):
			push_warning(
				"EasyLobby: nothing answering at noray %s:%d after %.1fs."
				% [host, port, _noray_connect_timeout]
			)
			return ERR_CANT_CONNECT

		var connect_err: Error = await Noray.connect_to_host(host, port)
		if connect_err != OK:
			return connect_err

	for attempt in _register_retries:
		var err := Noray.register_host()
		if err != OK:
			return err
		if await _await_signal(Noray.on_oid, _handshake_timeout) != null:
			return await Noray.register_remote(registrar_port)

	return ERR_TIMEOUT


## Start listening as the host. The OID from [method register] is the join code.
func host_lobby(max_players: int) -> Error:
	var port_err := await _ensure_bindable_port()
	if port_err != OK:
		return port_err

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(Noray.local_port, max_players)
	if err != OK:
		return err

	multiplayer.multiplayer_peer = peer
	_is_hosting = true

	# noray tells us whenever a client wants in, by either path. Both need us to
	# punch outward so the client's packets can get back through our NAT.
	if not Noray.on_connect_nat.is_connected(_open_mapping):
		Noray.on_connect_nat.connect(_open_mapping)
	if not Noray.on_connect_relay.is_connected(_open_mapping):
		Noray.on_connect_relay.connect(_open_mapping)

	# Not answering probes is half of forcing the relay: a client on this subnet
	# would otherwise find us and take the LAN shortcut no matter what the host wants.
	if _lan_enabled and not _force_relay:
		# Error is ok to swallow, noray is primary goal here.
		_lan.start_responding(_game_id, Noray.oid, Noray.local_port, _lan_discovery_port)
	stage_changed.emit(STAGE_CONNECTED_AS_HOST)
	return OK


## Host a lobby on this network.
func host_lan_lobby(code: String, max_players: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	# Port 0 takes whatever is free. Discovery advertises whatever we land on.
	var err := peer.create_server(0, max_players)
	if err != OK:
		return err

	var lan_err: Error = _lan.start_responding(
		_game_id, code, peer.host.get_local_port(), _lan_discovery_port
	)
	if lan_err != OK:
		peer.close()
		return lan_err

	multiplayer.multiplayer_peer = peer
	_is_hosting = true
	_lan_code = code

	if verbose_logging:
		print(
			"[EasyLobby] LAN: hosting %s on port %d, no noray"
			% [code, peer.host.get_local_port()]
		)

	stage_changed.emit(STAGE_CONNECTED_AS_HOST)
	return OK


## Join a host by code.
##
## Returns ERR_DOES_NOT_EXIST when the code resolves to no live host.
func join_lobby(code: String, offline := false) -> Error:
	if not offline:
		var port_err := await _ensure_bindable_port()
		if port_err != OK:
			return port_err

		_connect_error = ""
		if not Noray.on_command.is_connected(_validate_noray_response):
			Noray.on_command.connect(_validate_noray_response)

	var result := await _run_join_ladder(code, offline)

	if Noray.on_command.is_connected(_validate_noray_response):
		Noray.on_command.disconnect(_validate_noray_response)
	return result


## Work down the ladder, stopping at the first path that connects or
## try to connect only on LAN if [param offline] is true.
func _run_join_ladder(code: String, offline: bool) -> Error:
	if offline:
		return await _try_lan(code, LAN_ONLY_SEARCH_TIMEOUT_SEC)

	if _lan_enabled and not _force_relay and await _try_lan(code, _lan_timeout) == OK:
		return OK

	if not _force_relay:
		stage_changed.emit(STAGE_PUNCHING)
		if Noray.connect_nat(code) == OK:
			var nat := await _await_connect(Noray.on_connect_nat)
			if not _connect_error.is_empty():
				return ERR_DOES_NOT_EXIST
			if nat != null and await _try_connect(nat[0], nat[1]) == OK:
				stage_changed.emit(STAGE_CONNECTED_VIA_PUNCH)
				return OK

	stage_changed.emit(STAGE_RELAYING)
	if Noray.connect_relay(code) != OK:
		return ERR_CANT_CONNECT

	var relay := await _await_connect(Noray.on_connect_relay)
	if not _connect_error.is_empty() or relay == null:
		return ERR_DOES_NOT_EXIST

	var err := await _try_connect(relay[0], relay[1])
	if err == OK:
		stage_changed.emit(STAGE_CONNECTED_VIA_RELAY)
	return err


## Drop the multiplayer peer and stop responding to connection requests.
func teardown() -> void:
	if Noray.on_connect_nat.is_connected(_open_mapping):
		Noray.on_connect_nat.disconnect(_open_mapping)
	if Noray.on_connect_relay.is_connected(_open_mapping):
		Noray.on_connect_relay.disconnect(_open_mapping)

	_lan.stop()
	_lan_code = ""
	_is_hosting = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null


# --- Internals ----------------------------------------------------------------


## Whether this connection already holds a usable identity with noray.
##
## Note the socket check has to come first. netfox never clears _oid or
## _local_port, so those keep reading back long after a session has died.
func _is_registered() -> bool:
	return (
		Noray.is_connected_to_host()
		and not Noray.oid.is_empty()
		and Noray.local_port > 0
	)


## Whether anything is actually listening for noray at [param host]:[param port].
##
## This exists because netfox's connect_to_host polls its socket until it reports
## connected or errored, with no deadline of its own.
func _can_reach(host: String, port: int, timeout: float) -> bool:
	# netfox resolves the hostname too, but it does so inside the very call we are
	# trying not to make, so an unresolvable name has to be caught out here.
	var address := IP.resolve_hostname(host, IP.TYPE_IPV4)
	if address.is_empty():
		push_warning("EasyLobby: could not resolve noray host '%s'." % host)
		return false

	var probe := StreamPeerTCP.new()
	if probe.connect_to_host(address, port) != OK:
		return false

	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	var reachable := false
	while Time.get_ticks_msec() < deadline:
		probe.poll()
		var status := probe.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			reachable = true
			break
		if status == StreamPeerTCP.STATUS_ERROR:
			break
		await get_tree().process_frame

	probe.disconnect_from_host()

	if verbose_logging:
		print("[EasyLobby] noray at %s:%d reachable = %s" % [address, port, reachable])
	return reachable


func _ensure_bindable_port() -> Error:
	for attempt in range(4):
		var probe := PacketPeerUDP.new()
		var err := probe.bind(Noray.local_port)
		probe.close()
		if err == OK:
			return OK

		push_warning(
			"EasyLobby: noray assigned port %d but it is already in use; re-registering."
			% Noray.local_port
		)
		# Must force: the whole point is to be issued a different port, and a
		# plain register() would see us as already registered and no-op.
		var reregister_err := await register(_noray_host, _noray_port, _registrar_port, true)
		if reregister_err != OK:
			return reregister_err

	return ERR_CANT_CREATE


## Host side: open our NAT mapping toward a peer that noray has pointed at us.
func _open_mapping(address: String, port: int) -> void:
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if not _is_hosting or peer == null:
		return

	var key := "%s:%d" % [address, port]
	if _open_mappings.has(key):
		if verbose_logging:
			print("[EasyLobby] host: handshake to %s already running, skipping" % key)
		return
	_open_mappings[key] = true

	if verbose_logging:
		print("[EasyLobby] host: opening mapping to %s from local port %d" % [key, Noray.local_port])
	var err: Error = await PacketHandshake.over_enet(peer.host, address, port, _handshake_timeout)
	if verbose_logging:
		print("[EasyLobby] host: handshake to %s -> %s" % [key, error_string(err)])

	_open_mappings.erase(key)


## Send broadcasts looking for a host with [param code] and connect to the first one that answers.
##
## Shared by the ladder's first path attempt and by LAN-only joins. The two differ only in timeouts.
## Returns ERR_DOES_NOT_EXIST if nobody answers.
func _try_lan(code: String, search_timeout: float) -> Error:
	stage_changed.emit(STAGE_SEARCHING_LAN)

	var found: Variant = await _lan.find_host(
		_game_id, code, _lan_discovery_port, search_timeout
	)
	if found == null:
		return ERR_DOES_NOT_EXIST

	var address: String = found["address"]
	var port: int = found["port"]
	var err := await _connect_direct(address, port, LAN_CONNECT_TIMEOUT_SEC)
	if err == OK:
		stage_changed.emit(STAGE_CONNECTED_VIA_LAN)
	return err


## Bring up ENet straight against an address, skipping the punchthrough handshake. 
## Only correct for a peer on our own subnet.
func _connect_direct(address: String, port: int, timeout: float) -> Error:
	if verbose_logging:
		print("[EasyLobby] LAN: connecting directly to %s:%d" % [address, port])

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		if verbose_logging:
			print("[EasyLobby] LAN: create_client -> %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = peer

	var connected := await _await_multiplayer_connection(timeout)
	if verbose_logging:
		print("[EasyLobby] LAN: ENet connected = %s" % connected)
	if not connected:
		multiplayer.multiplayer_peer = null
		return ERR_CANT_CONNECT
	return OK


## Client side: handshake toward an address, then bring up ENet against it.
func _try_connect(address: String, port: int) -> Error:
	# The handshake must run on the port noray registered for us, otherwise the
	# NAT mapping it advertised points somewhere we aren't listening.
	var udp := PacketPeerUDP.new()
	var bind_err := udp.bind(Noray.local_port)
	if bind_err != OK:
		# Our registered port is held by something else, usually another
		# instance on this machine that was handed the same ephemeral port.
		push_warning(
			"EasyLobby: cannot bind registered port %d (%s). The handshake cannot run."
			% [Noray.local_port, error_string(bind_err)]
		)
		return bind_err
	udp.set_dest_address(address, port)

	if verbose_logging:
		print("[EasyLobby] client: handshaking %s:%d from local port %d"
			% [address, port, Noray.local_port])

	var err: Error = await PacketHandshake.over_packet_peer(udp, _handshake_timeout)
	udp.close()

	if verbose_logging:
		print("[EasyLobby] client: handshake -> %s" % error_string(err))

	# ERR_BUSY means packets crossed in both directions but mutual confirmation
	# never landed. That is usually still a usable path, and relaying instead
	# would cost real bandwidth, so it is worth an ENet attempt.
	if err != OK and err != ERR_BUSY:
		return err

	var peer := ENetMultiplayerPeer.new()
	err = peer.create_client(address, port, 0, 0, 0, Noray.local_port)
	if err != OK:
		if verbose_logging:
			print("[EasyLobby] client: create_client -> %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = peer

	# create_client() only starts the attempt, it says nothing about success.
	var connected := await _await_multiplayer_connection(_handshake_timeout)
	if verbose_logging:
		print("[EasyLobby] client: ENet connected = %s" % connected)
	if not connected:
		multiplayer.multiplayer_peer = null
		return ERR_CANT_CONNECT
	return OK


## Await ENet's verdict on an in-progress client connection.
func _await_multiplayer_connection(timeout: float) -> bool:
	var box := {"result": null}
	var on_ok := func() -> void: box.result = true
	var on_fail := func() -> void: box.result = false

	multiplayer.connected_to_server.connect(on_ok, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(on_fail, CONNECT_ONE_SHOT)

	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while box.result == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	if multiplayer.connected_to_server.is_connected(on_ok):
		multiplayer.connected_to_server.disconnect(on_ok)
	if multiplayer.connection_failed.is_connected(on_fail):
		multiplayer.connection_failed.disconnect(on_fail)

	return box.result == true


## Spot noray refusing a connect request for an unknown OID.
##
## noray replies to `connect` / `connect-relay` with an error payload rather
## than staying silent, and netfox's noray.gd does not check for that. It runs
## the payload through split(":") and emits on_connect_nat("\"Error", 0). Left
## alone that bogus address burns a full handshake timeout on both the
## punchthrough and relay attempts before failing, and reports "unreachable" for what
## is really "no such lobby". Catching the raw command is the only way to tell
## the two apart.
func _validate_noray_response(command: String, data: String) -> void:
	if command != "connect" and command != "connect-relay":
		return
	if data.begins_with("\"Error") or data.begins_with("Error"):
		_connect_error = data
		push_warning("EasyLobby: noray refused '%s' - %s" % [command, data])


## Await a connect response, giving up early if noray reports an error.
func _await_connect(sig: Signal) -> Variant:
	var box := {"args": null}
	var on_emit := func(a = null, b = null) -> void:
		if box.args == null:
			box.args = [a, b]
	sig.connect(on_emit, CONNECT_ONE_SHOT)

	var deadline := Time.get_ticks_msec() + int(_handshake_timeout * 1000.0)
	while box.args == null and _connect_error.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	if sig.is_connected(on_emit):
		sig.disconnect(on_emit)
	return null if not _connect_error.is_empty() else box.args


## Await [param sig], returning its arguments as an Array, or null on timeout.
##
## Every signal awaited here carries one or two arguments, which the default
## parameter values absorb.
func _await_signal(sig: Signal, timeout: float) -> Variant:
	var box := {"args": null}
	var on_emit := func(a = null, b = null) -> void:
		if box.args == null:
			box.args = [a, b]
	sig.connect(on_emit, CONNECT_ONE_SHOT)

	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while box.args == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	if sig.is_connected(on_emit):
		sig.disconnect(on_emit)
	return box.args
