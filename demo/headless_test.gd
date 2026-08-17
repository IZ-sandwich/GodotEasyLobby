extends Node

## Headless end-to-end harness used for automated testing. Not part of the addon.
##
##   godot --headless --path . res://demo/headless_test.tscn -- host
##   godot --headless --path . res://demo/headless_test.tscn -- join ABCDEF
##
## Prints machine-readable lines (CODE=, ROSTER=, OK, FAIL=) so a shell script
## can drive both sides and assert on the result.

const TIMEOUT_SEC := 300.0

var _role := ""
var _saw_peer := false
var _expect_failures := false
var _expect_closed := ""
## The chat message this role is waiting on, empty once it has arrived.
var _expect_chat := ""


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_fail("no role given")
		return
	_role = args[0]

	EasyLobby.lobby_created.connect(func(code: String) -> void: print("CODE=", code))
	EasyLobby.lobby_joined.connect(func(code: String) -> void: print("JOINED=", code))
	EasyLobby.lobby_join_failed.connect(func(reason: String) -> void:
		print("JOIN_FAILED=", reason)
		if not _expect_failures:
			_fail("join_failed:" + reason)
	)
	EasyLobby.lobby_closed.connect(_on_closed)
	EasyLobby.lobby_updated.connect(_on_updated)
	EasyLobby.connect_progress.connect(func(stage: String) -> void: print("STAGE=", stage))
	Noray.on_command.connect(func(cmd: String, data: String) -> void: print("NORAY=", cmd, " ", data))
	if _role.ends_with("-chat"):
		EasyLobby.chat_message_received.connect(_on_chat)

	_watchdog()

	match _role:
		"host":
			var err := await EasyLobby.create_lobby("Host")
			if err != OK:
				_fail("create_lobby:" + error_string(err))
		"join":
			if args.size() < 2:
				_fail("join needs a code")
				return
			var err := await EasyLobby.join_lobby(args[1], "Client")
			if err != OK:
				_fail("join_lobby:" + error_string(err))
		"filter":
			_check_filter()
			get_tree().quit(0)
		"retry":
			# Regression cover for the stale-registration bug: a failed join used
			# to re-register on the same TCP socket, and noray's findBySocket()
			# then kept handing out the FIRST registration's now-dead port, so
			# every subsequent attempt was doomed.
			if args.size() < 2:
				_fail("retry needs a code")
				return
			_expect_failures = true
			print("ATTEMPT=1 (deliberately bad code)")
			await EasyLobby.join_lobby("ZZZZZZ", "Client")
			print("ATTEMPT=2 (deliberately bad code)")
			await EasyLobby.join_lobby("YYYYYY", "Client")
			print("ATTEMPT=3 (real code)")
			var err := await EasyLobby.join_lobby(args[1], "Client")
			if err != OK:
				_fail("join_lobby after retries:" + error_string(err))
		"host-kick":
			var err := await EasyLobby.create_lobby("Host")
			if err != OK:
				_fail("create_lobby:" + error_string(err))
		"join-kicked":
			if args.size() < 2:
				_fail("join-kicked needs a code")
				return
			_expect_closed = EasyLobby.CLOSED_KICKED
			var err := await EasyLobby.join_lobby(args[1], "Client")
			if err != OK:
				_fail("join_lobby:" + error_string(err))
		"host-chat":
			# LAN-only, so the chat roles need no noray to run.
			var err := await EasyLobby.create_lobby("Host", 0, true)
			if err != OK:
				_fail("create_lobby:" + error_string(err))
				return
			_expect_chat = "ping"
			# Overrun the backlog before anyone joins, so the cap and the
			# history the joiner gets handed are both under test.
			for i in EasyLobby.MAX_CHAT_MESSAGES + 5:
				EasyLobby.send_chat("msg%d" % i)
			_check_backlog("msg5", "msg104")
		"join-chat":
			if args.size() < 2:
				_fail("join-chat needs a code")
				return
			_expect_chat = "pong"
			var err := await EasyLobby.join_lobby(args[1], "Client", true)
			if err != OK:
				_fail("join_lobby:" + error_string(err))
		"relay":
			# Probe the raw connect-relay payload shape, which is what the
			# _watch_command guard has to classify correctly.
			await _probe_relay(args[1] if args.size() > 1 else "")
		_:
			_fail("unknown role " + _role)


## The kicked side asserts on the reason; every other role just reports it.
func _on_closed(reason: String) -> void:
	print("CLOSED=", reason)
	if _expect_closed.is_empty():
		return
	if reason != _expect_closed:
		_fail("closed as '%s', expected '%s'" % [reason, _expect_closed])
		return
	print("OK")
	get_tree().quit(0)


func _on_updated() -> void:
	var names := EasyLobby.get_players().map(
		func(p: EasyLobbyPlayer) -> String: return "%d:%s" % [p.peer_id, p.player_name]
	)
	print("ROSTER=", ",".join(names))

	if EasyLobby.get_players().size() < 2 or _saw_peer:
		return
	_saw_peer = true

	match _role:
		"host-kick":
			# Whoever is not us, which at two players is the joiner.
			var target: int = EasyLobby.get_players()[1].peer_id
			print("KICKING=", target)
			await EasyLobby.kick(target)
			print("KICKED=", target)
			await get_tree().create_timer(1.0).timeout
			get_tree().quit(0)
		"join-kicked":
			pass  # the point of the run is what happens next; wait for it
		"host-chat":
			pass  # the exchange in _on_chat decides when this run is done
		"join-chat":
			# The backlog arrived with the roster, so it is readable already.
			_check_backlog("msg5", "msg104")
			EasyLobby.send_chat("ping")
		_:
			# Success for the plain roles is the same thing: two peers, one roster.
			print("OK")
			await get_tree().create_timer(1.0).timeout
			get_tree().quit(0)


## Chat arriving is what drives the two chat roles: the client opens with "ping"
## once it is in, the host answers "pong", and each side stops on the other's line.
func _on_chat(message: Dictionary) -> void:
	print("CHAT=%s: %s" % [message.player_name, message.text])
	if _expect_chat.is_empty() or message.text != _expect_chat:
		return
	_expect_chat = ""

	if _role == "host-chat":
		EasyLobby.send_chat("pong")
		# Give the reply time off the wire before tearing the lobby down.
		await get_tree().create_timer(1.0).timeout
	print("OK")
	get_tree().quit(0)


## Assert the backlog is capped and holds the newest messages, not the first ones.
func _check_backlog(expect_first: String, expect_last: String) -> void:
	var messages: Array = EasyLobby.get_chat_messages()
	var first: String = messages[0].text if not messages.is_empty() else ""
	var last: String = messages[-1].text if not messages.is_empty() else ""
	print("CHAT_BACKLOG=%d first=%s last=%s" % [messages.size(), first, last])

	if messages.size() != EasyLobby.MAX_CHAT_MESSAGES:
		_fail("backlog holds %d, expected %d" % [messages.size(), EasyLobby.MAX_CHAT_MESSAGES])
	elif first != expect_first or last != expect_last:
		_fail("backlog runs %s..%s, expected %s..%s" % [first, last, expect_first, expect_last])


## Assert EasyLobbyCodeFilter accepts ordinary codes and rejects ugly ones.
func _check_filter() -> void:
	var should_pass := [
		"ABCDEF", "KRPDXV", "ZZZZZZ", "QWERTY", "MNBVCX", "HEFXTJ",
		"ZASZZZ",  # "AS" is not "ASS" -- a doubled letter in the term is required
		"ZFUZKZ",  # letters of a blocked term, but broken up -- must not match
	]
	var should_fail := [
		"XXFAGX",  # substring, not the whole code
		"CUNTZZ",  # at the start
		"ZZZASS",  # at the end
		"AFUCKZ",  # in the middle
		"xxfagx",  # lowercase must still be caught
		# Padded out with repeated letters -- reads the same at a glance.
		"ZFUUCK", "FUCCKZ", "FFUCKZ", "ZFUCKK", "AASSZZ", "ZASSSZ",
		"SEEXZZ", "KKKKZZ", "ZFAAGZ", "CUUNTZ",
	]

	var failures := 0
	for code in should_pass:
		if EasyLobbyCodeFilter.is_offensive(code):
			print("FILTER_BAD= rejected a clean code: ", code)
			failures += 1
	for code in should_fail:
		if not EasyLobbyCodeFilter.is_offensive(code):
			print("FILTER_BAD= accepted an offensive code: ", code)
			failures += 1

	# Sanity-check the redraw rate: an over-eager list would make hosting slow.
	var rejected := 0
	var samples := 20000
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in samples:
		var code := ""
		for c in 6:
			code += EasyLobby.CODE_ALPHABET[rng.randi_range(0, EasyLobby.CODE_ALPHABET.length() - 1)]
		if EasyLobbyCodeFilter.is_offensive(code):
			rejected += 1

	print("FILTER_REJECT_RATE=%.3f%% (%d of %d)" % [100.0 * rejected / samples, rejected, samples])
	print("FILTER_FAILURES=", failures)
	if failures == 0:
		print("OK")


## Register, then ask noray for a relay directly, printing the raw reply.
func _probe_relay(code: String) -> void:
	Noray.connect_to_host(
		ProjectSettings.get_setting("easy_lobby/noray/host", "127.0.0.1"),
		ProjectSettings.get_setting("easy_lobby/noray/port", 8890),
	)
	await Noray.on_connect_to_host
	Noray.register_host()
	await Noray.on_pid
	await Noray.register_remote(ProjectSettings.get_setting("easy_lobby/noray/registrar_port", 8809))

	Noray.on_connect_relay.connect(
		func(address: String, port: int) -> void: print("RELAY_PARSED=", address, " ", port)
	)
	Noray.connect_relay(code)
	await get_tree().create_timer(5.0).timeout
	get_tree().quit(0)


func _watchdog() -> void:
	await get_tree().create_timer(TIMEOUT_SEC).timeout
	if not _saw_peer:
		_fail("timeout after %.0fs" % TIMEOUT_SEC)
	elif not _expect_closed.is_empty():
		_fail("timeout waiting for lobby_closed('%s')" % _expect_closed)
	elif not _expect_chat.is_empty():
		_fail("timeout waiting for the chat message '%s'" % _expect_chat)


func _fail(reason: String) -> void:
	print("FAIL=", reason)
	get_tree().quit(1)
