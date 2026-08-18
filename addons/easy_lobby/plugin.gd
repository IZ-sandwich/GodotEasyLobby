@tool
extends EditorPlugin

const AUTOLOAD_NAME := "EasyLobby"
const AUTOLOAD_PATH := "res://addons/easy_lobby/easy_lobby.gd"

# Defaults are for local testing - noray running on localhost. Change "easy_lobby/noray/host"
# value to your own server for anything other than same-machine testing.
var SETTINGS := [
	{"name": "easy_lobby/noray/host", "value": "127.0.0.1", "type": TYPE_STRING},
	{"name": "easy_lobby/noray/port", "value": 8890, "type": TYPE_INT},
	{"name": "easy_lobby/noray/registrar_port", "value": 8809, "type": TYPE_INT},
	{"name": "easy_lobby/lobby/max_players", "value": 8, "type": TYPE_INT},
	# Must match NORAY_OID_LENGTH on the server. 0 disables the length check,
	# which is what word-style OIDs need.
	{"name": "easy_lobby/lobby/code_length", "value": 6, "type": TYPE_INT},
	# Extra terms to reject in generated codes, on top of EasyLobbyCodeFilter's
	# built-in list. Useful for languages the built-in list does not cover.
	{
		"name": "easy_lobby/lobby/extra_blocked_terms",
		"value": PackedStringArray(),
		"type": TYPE_PACKED_STRING_ARRAY,
	},
	# Try the local network before noray when joining. Turn this off to only use
	# noray's punchthrough and relay paths.
	{"name": "easy_lobby/lan/enabled", "value": true, "type": TYPE_BOOL},
	# Where hosts answer discovery probes. Only has to be free on the host, and
	# only has to agree between the players in a session.
	{"name": "easy_lobby/lan/discovery_port", "value": 8898, "type": TYPE_INT},
	# Paid on every join that turns out not to be on the LAN, so keep it short.
	# A local subnet round trip is a couple of milliseconds.
	{"name": "easy_lobby/lan/discovery_timeout_sec", "value": 0.6, "type": TYPE_FLOAT},
	{"name": "easy_lobby/timeouts/handshake_sec", "value": 8.0, "type": TYPE_FLOAT},
	# How long to wait for noray's TCP port to answer before calling it unreachable.
	# netfox's own connect has no deadline and a refused connection can sit in
	# CONNECTING forever, so without this a down noray hangs instead of erroring.
	{"name": "easy_lobby/timeouts/noray_connect_sec", "value": 5.0, "type": TYPE_FLOAT},
	# A colliding OID makes noray's Repository.add() throw, so `set-oid` never
	# arrives and registration times out. Retrying is the fix.
	{"name": "easy_lobby/timeouts/register_retries", "value": 3, "type": TYPE_INT},
	# Prints every step of registration and the connect ladder.
	{"name": "easy_lobby/debug/verbose_logging", "value": false, "type": TYPE_BOOL},
	
	# --- Voice chat. All of it is ignored unless TwoVoip is installed. ---
	
	# Open the microphone on entering a lobby. Turn this off to ask the player
	# first and call EasyLobby.voice.start() yourself.
	{"name": "easy_lobby/voice/enabled", "value": true, "type": TYPE_BOOL},
	# Mono. No need to change this.
	{"name": "easy_lobby/voice/channels", "value": 1, "type": TYPE_INT},
	# The one setting that decides bandwidth. Can be improved to 24k if you want better quality.
	{"name": "easy_lobby/voice/bitrate", "value": 12000, "type": TYPE_INT},
	# Milliseconds of audio per packet. Lower is more responsive but spends more
	# on headers, which already dominate at these bitrates.
	{"name": "easy_lobby/voice/frame_ms", "value": 20, "type": TYPE_INT},
	# 48kHz is what Opus and the denoiser work at natively, so anything else costs a resample.
	{"name": "easy_lobby/voice/sample_rate", "value": 48000, "type": TYPE_INT},
	# Opus encoder complexity, 0-10. Higher is better quality but costs more CPU.
	{"name": "easy_lobby/voice/complexity", "value": 5, "type": TYPE_INT},
	# TwoVoip's RNNoise filter.
	{"name": "easy_lobby/voice/denoise", "value": true, "type": TYPE_BOOL},
	# How loud speech has to be to open the microphone without push to talk, 0 to 1.
	{"name": "easy_lobby/voice/vox_threshold", "value": 0.07, "type": TYPE_FLOAT},
	# Off means voice activation. On means the game drives
	# EasyLobby.voice.set_talking() from an input action.
	{"name": "easy_lobby/voice/push_to_talk", "value": false, "type": TYPE_BOOL},
]


func _enter_tree() -> void:
	for setting in SETTINGS:
		if not ProjectSettings.has_setting(setting.name):
			ProjectSettings.set_setting(setting.name, setting.value)
		ProjectSettings.set_initial_value(setting.name, setting.value)
		ProjectSettings.add_property_info({"name": setting.name, "type": setting.type})
	ProjectSettings.save()

	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
