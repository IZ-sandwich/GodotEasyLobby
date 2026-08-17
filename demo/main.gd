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


func _ready() -> void:
	_local_player_name_line_edit.text = "Player%d" % (randi() % 900 + 100)

	for mode in MODE_LABELS:
		_mode_option.add_item(MODE_LABELS[mode], mode)
	_mode_option.selected = Mode.AUTO

	EasyLobby.lobby_created.connect(_on_lobby_created)
	EasyLobby.lobby_joined.connect(_on_lobby_joined)
	EasyLobby.lobby_join_failed.connect(_on_join_failed)
	EasyLobby.lobby_closed.connect(_on_lobby_closed)
	EasyLobby.lobby_updated.connect(_refresh)
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
