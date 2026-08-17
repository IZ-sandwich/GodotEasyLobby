class_name EasyLobbyPlayer
extends RefCounted

## One player in the lobby roster.
##
## The host owns the authoritative roster and replicates it; clients hold copies.

## ENet peer id. The host is always 1.
var peer_id: int = 0

## Display name, chosen by the player.
var player_name: String = ""

## Ready flag, toggled by the player and relayed through the host.
var is_ready: bool = false

## Free-form per-player data the game can attach (character, colour, team...).
var custom: Dictionary = {}


static func from_dict(data: Dictionary) -> EasyLobbyPlayer:
	var player := EasyLobbyPlayer.new()
	player.peer_id = data.get("peer_id", 0)
	player.player_name = data.get("player_name", "")
	player.is_ready = data.get("is_ready", false)
	player.custom = data.get("custom", {})
	return player


## Only the replicated fields; local-only state is deliberately excluded.
func to_dict() -> Dictionary:
	return {
		"peer_id": peer_id,
		"player_name": player_name,
		"is_ready": is_ready,
		"custom": custom,
	}
