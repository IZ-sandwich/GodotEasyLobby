class_name EasyLobbyVoiceChat
extends Node

## Optional Opus voice chat, carried by the lobby's existing connection.
##
## Needs the TwoVoip GDExtension: https://github.com/goatchurchprime/two-voip-godot-4
## Without it this node still exists, but method calls do nothing.

## A player started or stopped talking. Covers the local player too.
signal speaking_changed(peer_id: int, speaking: bool)

# --- Constants ----------------------------------------------------------------

const MIC_SCRIPT := "res://addons/twovoip/voiphelper/two_voip_mic.gd"
const SPEAKER_SCRIPT := "res://addons/twovoip/voiphelper/two_voip_speaker.gd"

# Used for push to talk threshold 0 - fully open, 2 - fully closed.
const MIC_OPEN := 0.0
const MIC_SHUT := 2.0

# --- State --------------------------------------------------------------------

## Return the node a remote peer's voice should play out of, given its peer id.
## Anything with `set_stream()` and `play()` works. For example, an
## [AudioStreamPlayer3D] parented to a player's avatar gives positional voice.
## Whatever it returns must already be in the scene tree.
##
## If not set, each speaker gets a plain [AudioStreamPlayer] owned by this node,
## which is good enough for a lobby.
## Note: when a player leaves the lobby, this class frees the output node as well.
var output_factory: Callable

## The live `TwoVoipMic`, or null when voice is not running.
var mic: Node

## peer_id -> TwoVoipSpeaker
var _speakers := {}
## peer_id -> AudioStreamPlayer or whatever output_factory made
var _outputs := {}
## peer_id -> true, absent when silent
var _speaking := {}
## peer_id -> true once their utterance header has arrived. See _voice_data().
var _streaming := {}

## Local player's header while they are talking, empty otherwise.
var _stream_header := {}
var _late_joiners: Array[int] = []

var _muted := false
var _push_to_talk := false
var _push_to_talk_held := false
var _vox_threshold := 0.07
var _lobby: EasyLobby

## TwoVoip's own input-device picker, hidden and owned by the mic. See
## [method _select_input_item].
var _input_devices: OptionButton

var _input_device := ""
var _output_device := ""


func _ready() -> void:
	_lobby = get_parent()

	# Ideally these are saved as user settings.
	_vox_threshold = _get_setting("easy_lobby/voice/vox_threshold", 0.07)
	_push_to_talk = _get_setting("easy_lobby/voice/push_to_talk", false)

	# Hosting emits lobby_created, joining emits lobby_joined. _auto_start() is idempotent.
	_lobby.lobby_created.connect(func(_code: String) -> void: _auto_start())
	_lobby.lobby_joined.connect(func(_code: String) -> void: _auto_start())
	_lobby.lobby_closed.connect(func(_reason: String) -> void: stop())
	_lobby.player_joined.connect(_on_player_joined)
	_lobby.player_left.connect(_on_player_left)


# --- Public API ---------------------------------------------------------------


## Whether TwoVoip is installed.
static func is_available() -> bool:
	return (
		ClassDB.class_exists("TwovoipOpusEncoder")
		and ClassDB.class_exists("AudioStreamOpus")
		and ResourceLoader.exists(MIC_SCRIPT)
		and ResourceLoader.exists(SPEAKER_SCRIPT)
	)


## Whether voice is currently running locally.
func is_active() -> bool:
	return mic != null


## Start the microphone capture and transmission. Called automatically
## on joining a lobby unless easy_lobby/voice/enabled is off.
func start() -> void:
	if mic != null:
		return
	if not is_available():
		return

	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		push_warning(
			"EasyLobby: voice chat needs the project setting "
			+ "'audio/driver/enable_input' (Project Settings -> Audio -> Driver -> "
			+ "Enable Input) turned on."
		)
		return

	if get_input_devices().is_empty():
		push_warning("EasyLobby: no audio input device, so voice chat cannot start.")
		return

	mic = Node.new()
	mic.name = "TwoVoipMic"
	mic.set_script(load(MIC_SCRIPT))
	add_child(mic)

	# TwoVoip drives the microphone through UI controls rather than properties. Probably should rework this...
	# Making placeholders here, as children of the mic, so that they are freed with it
	# and a real UI can still call initvoipmic() again with its own.
	var mic_on := _make_toggle_button_placeholder(true)
	var ptt := _make_toggle_button_placeholder(false)
	# Voice activation stays on permanently; see _apply_threshold().
	var vox := _make_toggle_button_placeholder(true)
	var denoise := _make_toggle_button_placeholder(_get_setting("easy_lobby/voice/denoise", true))
	# initvoipmic() fills this in from the system's device list, so it has to go in
	# empty. This is also a placeholder node.
	_input_devices = OptionButton.new()
	_input_devices.visible = false
	mic.add_child(_input_devices)

	mic.transmitaudiojsonpacket.connect(_on_stream_marker)
	mic.transmitaudiopacket.connect(_on_opus_packet)

	# Order matters here. setopusvalues() reads the denoise button that this wires up.
	mic.initvoipmic(mic_on, _input_devices, ptt, vox, denoise, null)
	mic.setopusvalues(
		_get_setting("easy_lobby/voice/sample_rate", 48000),
		_get_setting("easy_lobby/voice/frame_ms", 20),
		_get_setting("easy_lobby/voice/channels", 1),
		_get_setting("easy_lobby/voice/bitrate", 12000),
		_get_setting("easy_lobby/voice/complexity", 5),
		true,
	)
	_apply_threshold()

	if _input_device.is_empty():
		_select_input_item(get_input_device())
	else:
		set_input_device(_input_device)


## Close the microphone and drop every remote voice stream.
func stop() -> void:
	if mic != null:
		# Disconnect before freeing.
		mic.transmitaudiojsonpacket.disconnect(_on_stream_marker)
		mic.transmitaudiopacket.disconnect(_on_opus_packet)
		mic.queue_free()
		mic = null
		_input_devices = null

	for peer_id in _speakers.keys():
		_free_speaker(peer_id)

	_speakers.clear()
	_outputs.clear()
	_streaming.clear()
	_stream_header.clear()
	_late_joiners.clear()
	_push_to_talk_held = false

	for peer_id in _speaking.keys():
		speaking_changed.emit(peer_id, false)
	_speaking.clear()


## Stop transmitting without tearing voice down. Everyone else is still audible.
func set_muted(muted: bool) -> void:
	_muted = muted
	_apply_threshold()


func is_muted() -> bool:
	return _muted


func set_push_to_talk(enabled: bool) -> void:
	_push_to_talk = enabled
	_push_to_talk_held = false
	_apply_threshold()


func is_push_to_talk() -> bool:
	return _push_to_talk


func set_push_to_talk_held(held: bool) -> void:
	_push_to_talk_held = held
	_apply_threshold()


func is_push_to_talk_held() -> bool:
	return _push_to_talk_held


## How loud speech has to be for voice activation to open the microphone, 0 to 1.
func set_vox_threshold(threshold: float) -> void:
	_vox_threshold = threshold
	_apply_threshold()


func get_vox_threshold() -> float:
	return _vox_threshold


## Microphone gain multiplier, 1.0 being unchanged.
func set_input_gain(gain: float) -> void:
	if mic != null:
		mic.set_gain(gain)


## Used to know if a peer is actually transmitting something.
func is_speaking(peer_id: int) -> bool:
	return _speaking.has(peer_id)


## The node a peer's voice plays out of, or null until they have spoken once.
## Use it to set per-player volume or an audio bus.
func get_output(peer_id: int) -> Node:
	return _outputs.get(peer_id)


# --- Audio devices ------------------------------------------------------------

# Thin wrappers over AudioServer, needed here because a player looks for
# both of these in the voice UI, and because switching microphone under a live
# capture takes more than setting the property. The lists are read from the OS on
# every call, so a headset plugged in mid-lobby shows up without a restart.


## Every microphone the system offers, `"Default"` is whatever the OS is set to.
func get_input_devices() -> PackedStringArray:
	return AudioServer.get_input_device_list()


## The microphone last chosen, used to recall it in the UI.
##
## Do not use [member AudioServer.input_device] - that reports the device the driver
## currently has open, and it does not change until the chosen device is actually used.
func get_input_device() -> String:
	return _input_device if not _input_device.is_empty() else AudioServer.input_device


## Switch microphone to one of [method get_input_devices].
func set_input_device(device: String) -> void:
	if not get_input_devices().has(device):
		push_warning("EasyLobby: no audio input device named '%s'." % device)
		return

	_input_device = device
	AudioServer.input_device = device
	_select_input_item(device)

	# A capture already running keeps reading the old device until the input
	# stream is stopped and started again.
	if mic != null:
		AudioServer.set_input_device_active(false)
		AudioServer.set_input_device_active(true)


## Every speaker the system offers, `"Default"` is first.
func get_output_devices() -> PackedStringArray:
	return AudioServer.get_output_device_list()


## The speaker last asked for, same behaviour as [method get_input_device].
func get_output_device() -> String:
	return _output_device if not _output_device.is_empty() else AudioServer.output_device


## Switch playback to one of [method get_output_devices].
##
## Godot mixes everything to one device, so this moves the whole game's audio, not just voice.
func set_output_device(device: String) -> void:
	if not get_output_devices().has(device):
		push_warning("EasyLobby: no audio output device named '%s'." % device)
		return
	_output_device = device
	AudioServer.output_device = device


# --- RPCs ---------------------------------------------------------------------

## Start and end of an utterance. TwoVoip brackets every one of these with a JSON
## marker and the opening one carries the Opus parameters. A listener that
## misses it cannot decode anything that follows hence using reliable.
@rpc("any_peer", "call_remote", "reliable")
func _voice_control(payload: PackedByteArray) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var speaker := _ensure_speaker(peer_id)
	if speaker == null:
		return

	var marker: Variant = JSON.parse_string(payload.get_string_from_ascii())
	var started: bool = marker is Dictionary and marker.has("talkingtimestart")
	_streaming[peer_id] = started
	speaker.tv_incomingaudiopacket(payload)
	_set_speaking(peer_id, started)


## One Opus frame, unreliable to improve latency.
##
## **Important:** Make sure the channel used here is different from your gameplay data.
@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _voice_data(packet: PackedByteArray) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	# Audio can outrun its own header, which arrives reliably on a different
	# channel. Decoding it then would index a decoder that is not set up yet, so
	# drop it. Costs a frame or two at the very start of an utterance.
	if not _streaming.get(peer_id, false):
		return

	var speaker: Node = _speakers.get(peer_id)
	if speaker != null:
		speaker.tv_incomingaudiopacket(packet)


# --- Internals ----------------------------------------------------------------


func _on_stream_marker(marker: Dictionary) -> void:
	if not _can_send():
		return
	var started: bool = marker.has("talkingtimestart")
	_stream_header = marker.duplicate() if started else {}
	_late_joiners.clear()
	_voice_control.rpc(JSON.stringify(marker).to_ascii_buffer())
	_set_speaking(multiplayer.get_unique_id(), started)


func _on_opus_packet(packet: PackedByteArray, frame_count: int) -> void:
	if not _can_send():
		return

	# Anyone who joined while another player is mid-utterance has no header yet.
	# Send them the current one stamped with how far the stream has got.
	if not _late_joiners.is_empty():
		if not _stream_header.is_empty():
			_stream_header["opusframecount"] = frame_count
			var payload := JSON.stringify(_stream_header).to_ascii_buffer()
			for peer_id in _late_joiners:
				_voice_control.rpc_id(peer_id, payload)
		_late_joiners.clear()

	_voice_data.rpc(packet)


## Entering a lobby opens the microphone, unless the game would rather ask first
## and call [method start] itself.
func _auto_start() -> void:
	if _get_setting("easy_lobby/voice/enabled", true):
		start()


func _can_send() -> bool:
	return multiplayer.multiplayer_peer != null


## Push-to-talk and muting use the voice-activation threshold.
## TwoVoip push to talk only works with a UI button being held down,
## so implementing like this for simplicity.
func _apply_threshold() -> void:
	if mic == null:
		return
	if _muted:
		mic.set_voxthreshhold(MIC_SHUT)
	elif _push_to_talk:
		mic.set_voxthreshhold(MIC_OPEN if _push_to_talk_held else MIC_SHUT)
	else:
		mic.set_voxthreshhold(_vox_threshold)


## Keep TwoVoip's hidden picker pointed at the device actually in use.
func _select_input_item(device: String) -> void:
	if _input_devices == null:
		return
	for index in _input_devices.item_count:
		if _input_devices.get_item_text(index) == device:
			_input_devices.select(index)
			return


func _make_toggle_button_placeholder(pressed: bool) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_pressed = pressed
	button.visible = false
	mic.add_child(button)
	return button


func _ensure_speaker(peer_id: int) -> Node:
	if _speakers.has(peer_id):
		return _speakers[peer_id]
	if not is_available():
		return null
	# Only allow players the host admitted to lobby. A rejected peer could still be connected for
	# the length of its disconnect grace window, but will not be in the player roster.
	if _lobby.get_player(peer_id) == null:
		return null

	var speaker := Node.new()
	speaker.name = "TwoVoipSpeaker"
	speaker.set_script(load(SPEAKER_SCRIPT))

	var output: Node = output_factory.call(peer_id) if output_factory.is_valid() else null
	var owned: bool = output == null
	if owned:
		output = AudioStreamPlayer.new()
		output.name = "Voice%d" % peer_id

	# TwoVoipSpeaker takes its output from its parent when it enters the tree, so
	# it has to be parented to the player before either of them gets there.
	output.add_child(speaker)
	if owned:
		add_child(output)

	_speakers[peer_id] = speaker
	_outputs[peer_id] = output
	return speaker


func _free_speaker(peer_id: int) -> void:
	var speaker: Node = _speakers.get(peer_id)
	if speaker != null:
		speaker.queue_free()

	var output: Node = _outputs.get(peer_id)
	if output != null and output.get_parent() == self:
		output.queue_free()


func _set_speaking(peer_id: int, speaking: bool) -> void:
	if _speaking.has(peer_id) == speaking:
		return
	if speaking:
		_speaking[peer_id] = true
	else:
		_speaking.erase(peer_id)
	speaking_changed.emit(peer_id, speaking)


func _on_player_joined(player: EasyLobbyPlayer) -> void:
	# Mid-utterance, so they need the header before they can decode anything.
	if not _stream_header.is_empty() and player.peer_id != multiplayer.get_unique_id():
		_late_joiners.append(player.peer_id)


func _on_player_left(peer_id: int) -> void:
	_free_speaker(peer_id)
	_speakers.erase(peer_id)
	_outputs.erase(peer_id)
	_streaming.erase(peer_id)
	_late_joiners.erase(peer_id)
	_set_speaking(peer_id, false)


func _get_setting(key: String, fallback: Variant) -> Variant:
	return ProjectSettings.get_setting(key, fallback)
