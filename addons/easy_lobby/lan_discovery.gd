class_name EasyLobbyLanDiscovery
extends Node

## UDP broadcast discovery, so two peers on the same network can find each other
## without going out to noray and back.
##
## noray only ever learns a peer's external address. When both peers sit
## behind the same router that address is the router's WAN side, so reaching it
## needs NAT hairpinning which plenty of consumer routers do not do.

## Wire prefix, so a stray packet on the discovery port is never mistaken for one
## of ours. Bump the digit if the payload format changes.
const MAGIC := "EZLOBBY1"

## Print each probe and answer.
var verbose_logging := false

var _socket: PacketPeerUDP = null
var _code := ""
var _game_port := 0


func _init() -> void:
	# Nothing to poll until start_responding() opens a socket.
	set_process(false)


## Host side: start answering discovery probes for [param code].
##
## [param game_port] is where our [ENetMultiplayerPeer] server is listening.
## This is what gets handed back to a joiner.
##
## Returns the bind error if the discovery port is unavailable.
func start_responding(code: String, game_port: int, discovery_port: int) -> Error:
	stop()

	var socket := PacketPeerUDP.new()
	var err := socket.bind(discovery_port)
	if err != OK:
		push_warning(
			(
				"EasyLobby: LAN discovery port %d is unavailable (%s); this lobby "
				+ "will only be reachable through noray."
			)
			% [discovery_port, error_string(err)]
		)
		return err

	_socket = socket
	_code = code
	_game_port = game_port
	set_process(true)

	if verbose_logging:
		print(
			"[EasyLobby] LAN: answering probes for %s on port %d, pointing at game port %d"
			% [code, discovery_port, game_port]
		)
	return OK


## Stop answering probes. Safe to call when not responding.
func stop() -> void:
	set_process(false)
	if _socket != null:
		_socket.close()
		_socket = null
	_code = ""
	_game_port = 0


## Client side: look for a host on this network serving [param code].
##
## Returns a [Dictionary] of `{"address": String, "port": int}`, or [code]null[/code]
## if nobody answered within [param timeout].
##
## This runs on every join, including ones that will end up going through noray,
## so [param timeout] is a direct cost on the common path. A local subnet round
## trip is a couple of milliseconds; keep it well under a second.
func find_host(
	code: String, discovery_port: int, timeout: float, interval := 0.1
) -> Variant:
	var socket := PacketPeerUDP.new()
	if socket.bind(0) != OK:
		return null
	socket.set_broadcast_enabled(true)

	var probe := (MAGIC + "?" + code).to_ascii_buffer()
	var expected := MAGIC + "!" + code + ":"
	var result: Variant = null
	var remaining := timeout

	while remaining > 0.0:
		# 127.0.0.1 is here just for testing locally, can be removed in prod.
		for target in ["255.255.255.255", "127.0.0.1"]:
			socket.set_dest_address(target, discovery_port)
			socket.put_packet(probe)

		await get_tree().create_timer(interval).timeout
		remaining -= interval

		while socket.get_available_packet_count() > 0:
			var payload := socket.get_packet().get_string_from_ascii()
			var address := socket.get_packet_ip()
			if not payload.begins_with(expected) or address.is_empty():
				continue
			var port := payload.substr(expected.length()).to_int()
			if port <= 0:
				continue
			result = {"address": address, "port": port}
			remaining = 0.0
			break

	socket.close()

	if verbose_logging:
		print("[EasyLobby] LAN: probe for %s -> %s" % [code, result])
	return result


# --- Internals ----------------------------------------------------------------


func _process(_delta: float) -> void:
	if _socket == null:
		return

	var query := MAGIC + "?" + _code
	var reply := "%s!%s:%d" % [MAGIC, _code, _game_port]

	while _socket.get_available_packet_count() > 0:
		var payload := _socket.get_packet().get_string_from_ascii()
		var address := _socket.get_packet_ip()
		var port := _socket.get_packet_port()

		if payload != query or address.is_empty():
			continue

		_socket.set_dest_address(address, port)
		_socket.put_packet(reply.to_ascii_buffer())

		if verbose_logging:
			print("[EasyLobby] LAN: answered probe from %s:%d" % [address, port])
