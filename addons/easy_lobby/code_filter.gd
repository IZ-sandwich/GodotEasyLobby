class_name EasyLobbyCodeFilter
extends RefCounted

## Codes are drawn at random, so a small fraction will spell something you would
## rather not put on a player's screen. This class determines when you should redraw.

## Terms shorter than this are not worth blocking, they collide with far too
## many innocent codes to be worth the redraws.
const MIN_TERM_LENGTH := 3

## Codes are spelled from [constant EasyLobby.CODE_ALPHABET]. 
## The default alphabet has no I, L or O, which by itself rules out most of the
## words you might expect to find in a list like this.
const BLOCKED := [
	"CUNT", "KUNT", "FAG", "QUEER", "TRANNY", "DYKE",
	"SPAZ", "KKK", "RAPE", "KYS",
	"FUCK", "FUK", "FCK", "FUX", "TWAT", "WANK",
	"PUSSY", "ARSE", "ASS", "AZZ", "ANUS", "TURD", "CRAP",
	"DAMN", "SUCK", "SUX", "STFU", "WTF", "SEX",
]


## Whether [param code] should be thrown back and redrawn.
static func is_offensive(code: String) -> bool:
	var candidate := code.to_upper()

	for term in BLOCKED:
		if _contains_stretched(candidate, term):
			return true

	# Games ship in more languages than this list covers, so let projects add
	# their own via easy_lobby/lobby/extra_blocked_terms.
	for term in extra_terms():
		var extra := String(term).to_upper()
		if extra.length() >= MIN_TERM_LENGTH and _contains_stretched(candidate, extra):
			return true
	return false


## Substring search that also matches terms padded out with repeated letters.
static func _contains_stretched(candidate: String, term: String) -> bool:
	for start in candidate.length():
		if _matches_at(candidate, term, start):
			return true
	return false


static func _matches_at(candidate: String, term: String, start: int) -> bool:
	var at := start
	for i in term.length():
		if at >= candidate.length() or candidate[at] != term[i]:
			return false
		at += 1

		# Swallow further copies of this letter but only when the term does
		# not itself repeat it next, or ASS would match AS.
		var term_repeats_letter := i + 1 < term.length() and term[i + 1] == term[i]
		if not term_repeats_letter:
			while at < candidate.length() and candidate[at] == term[i]:
				at += 1
	return true


## Project-supplied additions to [constant BLOCKED].
static func extra_terms() -> PackedStringArray:
	var configured = ProjectSettings.get_setting(
		"easy_lobby/lobby/extra_blocked_terms", PackedStringArray()
	)
	return configured if configured is PackedStringArray else PackedStringArray()
