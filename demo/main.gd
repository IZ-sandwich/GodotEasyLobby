extends Control

## Demo for EasyLobby. Check out the `README.md` and `deploy/README.md` for setup instructions
##
## Run two copies (Debug > Run Multiple Instances), host in one, paste the code into the other.
##
## Both copies must be on the same Connection mode: it decides whether noray is
## involved, and one peer cannot reach a lobby the other never advertised.

## normalize_code() and is_valid_code() are static, and reaching a static method
## through the EasyLobby autoload instance warns, so call them on the script.
const EasyLobbyScript := preload("res://addons/easy_lobby/easy_lobby.gd")

enum Mode {
	AUTO,  ## LAN first, then punchthrough, then relay.
	NORAY_ONLY,
	LAN_ONLY,
}

const MODE_LABELS := {
	Mode.AUTO: "Auto (LAN, then noray)",
	Mode.NORAY_ONLY: "noray only",
	Mode.LAN_ONLY: "LAN only (offline)",
}

const MODE_HINTS := {
	Mode.AUTO: "Tries the local network first, then noray.",
	Mode.NORAY_ONLY: "Only noray's punchthrough or relay.",
	Mode.LAN_ONLY: "No noray. Everyone must be on this network.",
}

## Hold to transmit with push-to-talk on. A hard-coded key rather than an input
## action, so the demo does not have to ship an InputMap entry. PushToTalkButton's
## tooltip in main.tscn names it, so change both together.
const PUSH_TO_TALK_KEY := KEY_V

@onready var _local_player_name_line_edit: LineEdit = %NameEdit
@onready var _lobby_code_line_edit: LineEdit = %CodeEdit
@onready var _mode_row: HBoxContainer = %ModeRow
@onready var _mode_option: OptionButton = %ModeOption
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _paste_button: Button = %PasteButton
@onready var _copy_button: Button = %CopyButton
@onready var _hide_code_button: CheckButton = %HideCodeButton
@onready var _lobby_code_label: Label = %CodeLabel
@onready var _lobby_seal_button: CheckBox = %SealButton
@onready var _ready_button: CheckBox = %ReadyButton
@onready var _leave_button: Button = %LeaveButton
@onready var _status_label: Label = %StatusLabel
@onready var _player_roster: VBoxContainer = %PlayerRoster
@onready var _chat_log: RichTextLabel = %ChatLog
@onready var _chat_row: HBoxContainer = %ChatRow
@onready var _chat_line_edit: LineEdit = %ChatEdit

## The voice row. Hidden wholesale when TwoVoip is not installed, which is the
## only reason any of it is optional - see _refresh_voice().
@onready var _voice_row: HFlowContainer = %VoiceRow
@onready var _input_device_option: OptionButton = %InputDeviceOption
@onready var _output_device_option: OptionButton = %OutputDeviceOption
@onready var _mic_button: CheckButton = %MicButton
@onready var _push_to_talk_button: CheckButton = %PushToTalkButton
@onready var _talk_button: Button = %TalkButton


func _ready() -> void:
	_local_player_name_line_edit.text = "Player%d" % (randi() % 900 + 100)

	for mode in MODE_LABELS:
		_mode_option.add_item(MODE_LABELS[mode], mode)
	_mode_option.selected = Mode.AUTO

	# The one part of the voice row the scene cannot hold: the device lists come
	# from the OS, and are rebuilt every time a picker is opened rather than once
	# here, since headsets get plugged in and pulled out while the game runs.
	# about_to_popup is on the popup rather than on the button, so it cannot be
	# wired up in the scene either.
	_input_device_option.get_popup().about_to_popup.connect(_refresh_input_devices)
	_output_device_option.get_popup().about_to_popup.connect(_refresh_output_devices)
	_refresh_input_devices()
	_refresh_output_devices()

	EasyLobby.voice.speaking_changed.connect(func(_id: int, _talking: bool) -> void: _refresh())

	EasyLobby.lobby_created.connect(_on_lobby_created)
	EasyLobby.lobby_joined.connect(_on_lobby_joined)
	EasyLobby.lobby_join_failed.connect(_on_join_failed)
	EasyLobby.lobby_closed.connect(_on_lobby_closed)
	EasyLobby.lobby_updated.connect(_refresh)
	EasyLobby.chat_message_received.connect(func(_message: Dictionary) -> void: _refresh_chat())
	EasyLobby.connect_progress.connect(func(stage: String) -> void: _set_status(stage + "..."))

	_refresh()


# --- Actions ------------------------------------------------------------------


func _on_mode_option_item_selected(index: int) -> void:
	_set_status(MODE_HINTS[_mode_option.get_item_id(index)])


func _on_host_button_pressed() -> void:
	var offline := _apply_mode()
	_set_status("Setting up the lobby..." if offline else "Registering with noray...")
	_set_busy(true)
	var err := await EasyLobby.create_lobby(_local_player_name_line_edit.text, 0, offline)
	_set_busy(false)
	if err != OK:
		# Only one of these modes has a server that can be down.
		_set_status(
			"Could not host: %s." % error_string(err) if offline
			else "Could not host: %s. Is noray running?" % error_string(err)
		)


func _on_join_button_pressed() -> void:
	var offline := _apply_mode()
	_set_status("Searching the local network..." if offline else "Connecting...")
	_set_busy(true)
	await EasyLobby.join_lobby(
		_lobby_code_line_edit.text, _local_player_name_line_edit.text, offline
	)
	_set_busy(false)


func _on_code_edit_text_submitted(_text: String) -> void:
	if not _join_button.disabled:
		_on_join_button_pressed()


func _on_copy_button_pressed() -> void:
	DisplayServer.clipboard_set(EasyLobby.code)
	_set_status("Join code copied to the clipboard.")


func _on_paste_button_pressed() -> void:
	var pasted := EasyLobbyScript.normalize_code(DisplayServer.clipboard_get())
	if pasted.is_empty():
		_set_status("Nothing on the clipboard to paste.")
		return

	_lobby_code_line_edit.text = pasted
	_lobby_code_line_edit.caret_column = pasted.length()
	if EasyLobbyScript.is_valid_code(pasted):
		_set_status("Pasted the code from the clipboard.")
	else:
		_set_status("Pasted the clipboard, but it doesn't look like a join code.")


func _on_hide_code_button_toggled(_toggled_on: bool) -> void:
	_refresh_code_display()


func _on_seal_button_toggled(toggled_on: bool) -> void:
	EasyLobby.seal_lobby(toggled_on)


func _on_ready_button_toggled(toggled_on: bool) -> void:
	EasyLobby.set_ready(toggled_on)


func _on_leave_button_pressed() -> void:
	EasyLobby.leave_lobby()


func _on_chat_edit_text_submitted(_text: String) -> void:
	_send_chat()


func _on_chat_send_button_pressed() -> void:
	_send_chat()


func _send_chat() -> void:
	EasyLobby.send_chat(_chat_line_edit.text)
	_chat_line_edit.clear()
	_chat_line_edit.grab_focus()


# --- Voice --------------------------------------------------------------------


func _on_mic_button_toggled(toggled_on: bool) -> void:
	EasyLobby.voice.set_muted(not toggled_on)


func _on_push_to_talk_button_toggled(toggled_on: bool) -> void:
	EasyLobby.voice.set_push_to_talk(toggled_on)
	if toggled_on:
		_set_status(
			"Push to talk: hold Talk, or %s while the chat box is not focused."
			% OS.get_keycode_string(PUSH_TO_TALK_KEY)
		)
	else:
		_set_status("Voice activation: the mic opens when you speak.")
	_refresh()


func _on_talk_button_button_down() -> void:
	EasyLobby.voice.set_push_to_talk_held(true)


func _on_talk_button_button_up() -> void:
	EasyLobby.voice.set_push_to_talk_held(false)


func _on_input_device_option_item_selected(index: int) -> void:
	EasyLobby.voice.set_input_device(_input_device_option.get_item_text(index))


func _on_output_device_option_item_selected(index: int) -> void:
	EasyLobby.voice.set_output_device(_output_device_option.get_item_text(index))


func _refresh_input_devices() -> void:
	var devices: PackedStringArray = EasyLobby.voice.get_input_devices()
	var current: String = EasyLobby.voice.get_input_device()
	_fill_device_option(_input_device_option, devices, current)


func _refresh_output_devices() -> void:
	var devices: PackedStringArray = EasyLobby.voice.get_output_devices()
	var current: String = EasyLobby.voice.get_output_device()
	_fill_device_option(_output_device_option, devices, current)


## Rebuild a device dropdown, leaving [param current] as the selected entry.
func _fill_device_option(
	option: OptionButton, devices: PackedStringArray, current: String
) -> void:
	option.clear()
	for device in devices:
		option.add_item(device)
		# select() rather than letting add_item() pick, and neither one emits, so
		# this only mirrors a choice that has already taken effect.
		if device == current:
			option.select(option.item_count - 1)


## Push-to-talk on a key as well as on the Talk button. Unhandled input only, so
## typing a "v" into the chat box does not open the microphone.
func _unhandled_key_input(event: InputEvent) -> void:
	if not EasyLobby.voice.is_push_to_talk():
		return

	var key := event as InputEventKey
	if key == null or key.echo or key.keycode != PUSH_TO_TALK_KEY:
		return

	EasyLobby.voice.set_push_to_talk_held(key.pressed)
	get_viewport().set_input_as_handled()


# --- Signal handlers ----------------------------------------------------------


func _on_lobby_created(_code: String) -> void:
	_set_status("Hosting. Share the code below with the other players.")
	_refresh()


func _on_lobby_joined(_code: String) -> void:
	_set_status("Joined the lobby.")
	_refresh()


func _on_join_failed(reason: String) -> void:
	var messages := {
		EasyLobby.JOIN_BAD_CODE: "That code isn't valid.",
		EasyLobby.JOIN_NORAY_SERVER_UNREACHABLE: "Can't reach noray.",
		EasyLobby.JOIN_NOT_FOUND: "No lobby with that code.",
		EasyLobby.JOIN_UNREACHABLE: "Found the lobby, but couldn't connect.",
		EasyLobby.JOIN_FULL: "That lobby is full.",
		EasyLobby.JOIN_SEALED: "That lobby has already started.",
	}
	_set_status(messages.get(reason, reason))
	_refresh()


func _on_lobby_closed(reason: String) -> void:
	var messages := {
		EasyLobby.CLOSED_HOST_LEFT: "The host left, so the lobby ended.",
		EasyLobby.CLOSED_KICKED: "You were removed from the lobby.",
		EasyLobby.CLOSED_LEFT: "Left the lobby.",
	}
	_set_status(messages.get(reason, reason))
	_refresh()


# --- View ---------------------------------------------------------------------


func _refresh() -> void:
	var in_lobby := EasyLobby.is_in_lobby()

	_host_button.visible = not in_lobby
	_join_button.visible = not in_lobby
	_lobby_code_line_edit.visible = not in_lobby
	_mode_row.visible = not in_lobby

	_paste_button.visible = not in_lobby and DisplayServer.has_feature(
		DisplayServer.FEATURE_CLIPBOARD
	)
	_local_player_name_line_edit.editable = not in_lobby

	_refresh_code_display()
	_lobby_code_label.visible = in_lobby

	_copy_button.visible = (
		in_lobby and EasyLobby.is_host and DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD)
	)
	_lobby_seal_button.visible = in_lobby and EasyLobby.is_host
	_lobby_seal_button.set_pressed_no_signal(EasyLobby.sealed)
	_ready_button.visible = in_lobby
	_leave_button.visible = in_lobby
	_chat_log.visible = in_lobby
	_chat_row.visible = in_lobby
	_refresh_voice()
	_refresh_chat()

	for child in _player_roster.get_children():
		child.queue_free()

	if not in_lobby:
		return

	var local_id := multiplayer.get_unique_id()
	for player in EasyLobby.get_players():
		var row := HBoxContainer.new()

		var label := Label.new()
		var tags := []
		if player.peer_id == 1:
			tags.append("host")
		if player.peer_id == local_id:
			tags.append("you")
		if EasyLobby.voice.is_speaking(player.peer_id):
			tags.append("talking")
		label.text = "%s %s %s" % [
			"[x]" if player.is_ready else "[ ]",
			player.player_name,
			"(%s)" % ", ".join(tags) if not tags.is_empty() else "",
		]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		if EasyLobby.is_host and player.peer_id != 1:
			var kick := Button.new()
			kick.text = "Kick"
			kick.pressed.connect(EasyLobby.kick.bind(player.peer_id))
			row.add_child(kick)

		_player_roster.add_child(row)

	if EasyLobby.all_ready():
		var note := Label.new()
		note.text = "Everyone is ready."
		_player_roster.add_child(note)


## Unlike the rest of the UI this stays up outside a lobby: picking a microphone
## before joining is the normal way round, and the addon honours a device, a mute
## and a push-to-talk choice made while voice is not running.
func _refresh_voice() -> void:
	# Installed, and either set to open the mic on joining or already running -
	# a game that turned the setting off and never calls start() has no voice to
	# configure, so there is nothing to show.
	var opens_on_join: bool = ProjectSettings.get_setting("easy_lobby/voice/enabled", true)
	_voice_row.visible = (
		EasyLobbyVoiceChat.is_available() and (opens_on_join or EasyLobby.voice.is_active())
	)
	if not _voice_row.visible:
		return

	# Read back rather than assumed: the addon starts from the project settings,
	# and mute or push-to-talk may have been set from code as well as from here.
	_mic_button.set_pressed_no_signal(not EasyLobby.voice.is_muted())
	_push_to_talk_button.set_pressed_no_signal(EasyLobby.voice.is_push_to_talk())
	_talk_button.visible = EasyLobby.voice.is_push_to_talk()
	_talk_button.disabled = not EasyLobby.voice.is_active()


## Redraw the whole backlog rather than appending to it, since the addon drops
## the oldest message once it is full and there is no cheap way to mirror that.
## The label's scroll_following keeps the newest line in view.
func _refresh_chat() -> void:
	var lines := PackedStringArray()
	for message in EasyLobby.get_chat_messages():
		lines.append("%s: %s" % [message.player_name, message.text])
	_chat_log.text = "\n".join(lines)


func _refresh_code_display() -> void:
	var masked := _hide_code_button.button_pressed
	# No secret feature for a label, so do it this way.
	_lobby_code_label.text = (
		"*".repeat(EasyLobby.code.length()) if masked else EasyLobby.code
	)
	_lobby_code_line_edit.text = EasyLobby.code
	_lobby_code_line_edit.secret = masked


## Push the selected mode into the addon, and report whether it is the offline one.
##
## easy_lobby re-reads the LAN setting on every create/join
func _apply_mode() -> bool:
	var mode := _mode_option.get_selected_id()
	ProjectSettings.set_setting("easy_lobby/lan/enabled", mode != Mode.NORAY_ONLY)
	return mode == Mode.LAN_ONLY


func _set_busy(busy: bool) -> void:
	_host_button.disabled = busy
	_join_button.disabled = busy
	_mode_option.disabled = busy


func _set_status(text: String) -> void:
	_status_label.text = text
