extends Node

## Headless end-to-end harness used for automated testing. Not part of the addon.
##
##   godot --headless --path . res://demo/headless_test.tscn -- host
##   godot --headless --path . res://demo/headless_test.tscn -- join ABCDEF
##
## The game id roles pair up over LAN, so they need no noray either:
##
##   godot ... -- host-lan                    # plain LAN host, kill it when done
##   godot ... -- join-other-game ABCDEF      # different id, discovery must miss
##   godot ... -- host-lan some-other-game    # host moves its id after hosting
##   godot ... -- join-wrong-game ABCDEF      # gets in, must be turned away
##
## The "filter", "voice" and "game-id" roles are self-contained and need no
## second instance.
## Run "voice" without --headless (use --display-driver headless) to get a real
## audio driver and more than one device to switch between.
##
## Prints machine-readable lines (CODE=, ROSTER=, OK, FAIL=) so a shell script
## can drive both sides and assert on the result.

## Reaching a static method through the EasyLobby autoload instance warns, so
## call them on the script.
const EasyLobbyScript := preload("res://addons/easy_lobby/easy_lobby.gd")

const TIMEOUT_SEC := 300.0

var _role := ""
var _saw_peer := false
var _expect_failures := false
var _expect_closed := ""
## The JOIN_* reason this role is waiting to be turned away with. Unlike
## _expect_failures, getting in is the failure.
var _expect_join_failure := ""
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
	EasyLobby.lobby_join_failed.connect(_on_join_failed)
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
		"voice":
			_check_voice()
			get_tree().quit(0)
		"game-id":
			_check_game_id()
			get_tree().quit(0)
		"host-lan":
			# A LAN lobby that just sits there, for the two roles below to aim at.
			# Meant to be killed by whatever drives it rather than to finish.
			var err := await EasyLobby.create_lobby("Host", 0, true)
			if err != OK:
				_fail("create_lobby:" + error_string(err))
				return
			# With a second argument, move the game id out from under the lobby.
			# LAN discovery captured its own when the lobby came up, so it keeps
			# answering under the old id while the join handshake checks the new
			# one - which is exactly the state a peer arriving from another game
			# on a shared noray puts the host in, minus needing a shared noray.
			if args.size() > 1:
				ProjectSettings.set_setting("easy_lobby/lobby/game_id", args[1])
				print("GAME_ID_NOW=", EasyLobbyScript.get_game_id())
		"join-wrong-game":
			if args.size() < 2:
				_fail("join-wrong-game needs a code")
				return
			_expect_join_failure = EasyLobby.JOIN_WRONG_GAME_ID
			var err := await EasyLobby.join_lobby(args[1], "Client", true)
			if err != OK:
				_fail("join_lobby:" + error_string(err))
		"join-other-game":
			# The other half: a mismatch the host never even hears about, because
			# discovery is scoped by game id and no one answers the probe.
			if args.size() < 2:
				_fail("join-other-game needs a code")
				return
			ProjectSettings.set_setting("easy_lobby/lobby/game_id", "some-other-game")
			_expect_join_failure = EasyLobby.JOIN_NOT_FOUND
			var err := await EasyLobby.join_lobby(args[1], "Client", true)
			if err != OK and err != ERR_DOES_NOT_EXIST:
				_fail("join_lobby:" + error_string(err))
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


## The roles that expect to be turned away assert on the reason; the rest treat
## any failure as a failed run.
func _on_join_failed(reason: String) -> void:
	print("JOIN_FAILED=", reason)

	if not _expect_join_failure.is_empty():
		if reason != _expect_join_failure:
			_fail("turned away with '%s', expected '%s'" % [reason, _expect_join_failure])
			return
		print("OK")
		get_tree().quit(0)
		return

	if not _expect_failures:
		_fail("join_failed:" + reason)


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


## Assert the voice device and push-to-talk API with TwoVoip absent, which is the
## configuration a machine without the extension can still cover: all of this is
## AudioServer and local state, so none of it needs a microphone or a lobby.
##
## Under --headless the audio driver is a dummy with one device called "Default",
## so the interesting assertions here are the ones about refusing a bogus name
## and about not reading a device back off AudioServer, which only reports what
## the driver currently has open.
func _check_voice() -> void:
	var voice: EasyLobbyVoiceChat = EasyLobby.voice
	var failures := 0

	print("VOICE_AVAILABLE=", EasyLobbyVoiceChat.is_available())
	print("VOICE_INPUTS=", ", ".join(voice.get_input_devices()))
	print("VOICE_OUTPUTS=", ", ".join(voice.get_output_devices()))

	# A name that is not on the list has to be refused. AudioServer would take it
	# and quietly fall back to "Default", which looks like the switch worked.
	var input_before: String = voice.get_input_device()
	voice.set_input_device("no such microphone")
	if voice.get_input_device() != input_before:
		print("VOICE_BAD= a bogus microphone changed the selection")
		failures += 1

	var output_before: String = voice.get_output_device()
	voice.set_output_device("no such speaker")
	if voice.get_output_device() != output_before:
		print("VOICE_BAD= a bogus speaker changed the selection")
		failures += 1

	# Every real device has to read back, "Default" included, or a settings menu
	# cannot show the player what they picked.
	for device in voice.get_input_devices():
		voice.set_input_device(device)
		if voice.get_input_device() != device:
			print("VOICE_BAD= microphone did not stick: ", device)
			failures += 1
	for device in voice.get_output_devices():
		voice.set_output_device(device)
		if voice.get_output_device() != device:
			print("VOICE_BAD= speaker did not stick: ", device)
			failures += 1

	voice.set_input_device(input_before)
	voice.set_output_device(output_before)

	# Push-to-talk is local state, so it answers with TwoVoip missing too.
	voice.set_push_to_talk(true)
	voice.set_push_to_talk_held(true)
	if not voice.is_push_to_talk() or not voice.is_push_to_talk_held():
		print("VOICE_BAD= push-to-talk did not take")
		failures += 1

	# Leaving push-to-talk has to drop a held key with it, or the mic would sit
	# open the moment voice activation takes over.
	voice.set_push_to_talk(false)
	if voice.is_push_to_talk() or voice.is_push_to_talk_held():
		print("VOICE_BAD= leaving push-to-talk left it talking")
		failures += 1

	print("VOICE_FAILURES=", failures)
	if failures == 0:
		print("OK")


## Assert how the game id resolves: an explicit setting wins, anything blank
## falls back to the project name so two projects differ without being told to,
## and the application version is appended only when there is one.
##
## All ProjectSettings, so this needs neither a lobby nor a network.
func _check_game_id() -> void:
	var original: String = ProjectSettings.get_setting("easy_lobby/lobby/game_id", "")
	var original_version: String = ProjectSettings.get_setting("application/config/version", "")
	var project_name: String = ProjectSettings.get_setting("application/config/name", "")
	var failures := 0

	# [game_id setting, version setting] -> what the handshake should carry.
	var cases := {
		["forest-brawl", ""]: "forest-brawl",
		# Whitespace is not an id. Falling back beats handshaking on " ".
		["   ", ""]: project_name,
		["", ""]: project_name,
		# Trimmed, so a stray space pasted into either setting cannot split two
		# builds that are otherwise the same game.
		["  forest-brawl  ", "  3  "]: "forest-brawl@3",
		# Godot leaves config/version blank, so an unset version has to mean no
		# version rather than a dangling separator.
		["forest-brawl", "   "]: "forest-brawl",
		["forest-brawl", "1.2"]: "forest-brawl@1.2",
		["", "1.2"]: project_name + "@1.2",
	}

	for case in cases:
		ProjectSettings.set_setting("easy_lobby/lobby/game_id", case[0])
		ProjectSettings.set_setting("application/config/version", case[1])
		var resolved := EasyLobbyScript.get_game_id()
		print("GAME_ID['%s' v'%s']=%s" % [case[0], case[1], resolved])
		if resolved != cases[case]:
			print("GAME_ID_BAD= '%s'/'%s' resolved to '%s', expected '%s'" % [
				case[0], case[1], resolved, cases[case]
			])
			failures += 1

	ProjectSettings.set_setting("easy_lobby/lobby/game_id", original)
	ProjectSettings.set_setting("application/config/version", original_version)

	print("GAME_ID_FAILURES=", failures)
	if failures == 0:
		print("OK")


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
	elif not _expect_join_failure.is_empty():
		_fail("timeout waiting to be turned away with '%s'" % _expect_join_failure)
	elif not _expect_chat.is_empty():
		_fail("timeout waiting for the chat message '%s'" % _expect_chat)


func _fail(reason: String) -> void:
	print("FAIL=", reason)
	get_tree().quit(1)
