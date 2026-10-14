@tool
class_name SynthKeyboard
extends Control

# An on-screen piano for auditioning a patch: `octaves` octaves starting at the C
# `first_note`. Click or drag across it to play; the owner turns note_pressed /
# note_released into sound and calls set_held() to light the keys that sound.
#
# `played` marks the keys the game itself plays this patch at (the roots of its
# baked sample set): key midi -> the loudest velocity recorded for it.

signal note_pressed(note: int)
signal note_released(note: int)

const WHITE_STEPS := [0, 2, 4, 5, 7, 9, 11]
# Black key: after which white key (index in WHITE_STEPS), and its semitone.
const BLACK_AFTER := {0: 1, 1: 3, 3: 6, 4: 8, 5: 10}

var first_note: int = 48:
	set(v):
		first_note = clampi(v - posmod(v, 12), 0, 108 - octaves * 12)
		queue_redraw()
var octaves: int = 3:
	set(v):
		octaves = clampi(v, 1, 5)
		queue_redraw()
## midi -> loudest velocity the game plays it at.
var played: Dictionary = {}:
	set(v):
		played = v
		queue_redraw()

var _held: Dictionary = {}     # midi -> true, keys that sound now
var _mouse_note: int = -1      # key under a pressed mouse button

func _init() -> void:
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready() -> void:
	custom_minimum_size = Vector2(120, 88.0 * SynthRackStyle.scale(self))

func set_held(note: int, on: bool) -> void:
	if on:
		_held[note] = true
	else:
		_held.erase(note)
	queue_redraw()

func clear_held() -> void:
	_held.clear()
	queue_redraw()

func get_last_note() -> int:
	return first_note + octaves * 12 - 1

## Shift so the keyboard shows [param note], keeping its octave count.
func show_note(note: int) -> void:
	if note < first_note or note > get_last_note():
		first_note = note - posmod(note, 12)

# --- geometry -----------------------------------------------------------------

func _white_count() -> int:
	return octaves * 7 + 1  # ends on the C above the last octave

# Rect of the white key [param index] (0 = first_note) and the note it is.
func _white_rect(index: int) -> Rect2:
	var w: float = size.x / float(_white_count())
	return Rect2(index * w, 0, w, size.y)

func _white_note(index: int) -> int:
	return first_note + (index / 7) * 12 + WHITE_STEPS[index % 7]

# [note, rect] for each black key.
func _black_keys() -> Array:
	var out: Array = []
	var w: float = size.x / float(_white_count())
	for oct in octaves:
		for wi in BLACK_AFTER:
			var idx: int = oct * 7 + wi
			var x: float = (idx + 1) * w - w * 0.3
			out.append([first_note + oct * 12 + BLACK_AFTER[wi], Rect2(x, 0, w * 0.6, size.y * 0.62)])
	return out

func note_at(pos: Vector2) -> int:
	if pos.x < 0.0 or pos.y < 0.0 or pos.x >= size.x or pos.y >= size.y:
		return -1
	for bk in _black_keys():
		if (bk[1] as Rect2).has_point(pos):
			return bk[0]
	var w: float = size.x / float(_white_count())
	return _white_note(clampi(int(pos.x / w), 0, _white_count() - 1))

# --- drawing ------------------------------------------------------------------

func _draw() -> void:
	var s := SynthRackStyle.scale(self)
	var acc := SynthRackStyle.accent(self)
	var mark := SynthRackStyle.marker(self)
	var fnt := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.72)
	var white := Color(0.9, 0.91, 0.93)
	var black := Color(0.1, 0.11, 0.13)
	var edge := Color(0, 0, 0, 0.45)
	for i in _white_count():
		var note := _white_note(i)
		var r := _white_rect(i)
		var c := white
		if _held.has(note):
			c = acc.lightened(0.15)
		elif played.has(note):
			c = white.lerp(mark, 0.45)
		draw_rect(Rect2(r.position + Vector2(1, 0), r.size - Vector2(1, 1)), c)
		draw_line(r.position + Vector2(r.size.x, 0), r.end, edge, 1.0)
		if played.has(note):
			draw_circle(Vector2(r.position.x + r.size.x * 0.5, r.end.y - 10.0 * s), 3.0 * s, mark.darkened(0.2))
		if note % 12 == 0:
			var txt := SynthRackStyle.note_name(note)
			draw_string(fnt, Vector2(r.position.x + 3.0 * s, r.end.y - 2.0 * s), txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.25, 0.27, 0.3))
	for bk in _black_keys():
		var note: int = bk[0]
		var r: Rect2 = bk[1]
		var c := black
		if _held.has(note):
			c = acc.darkened(0.1)
		elif played.has(note):
			c = black.lerp(mark, 0.55)
		draw_rect(r, c)
		if played.has(note):
			draw_circle(Vector2(r.position.x + r.size.x * 0.5, r.end.y - 7.0 * s), 2.5 * s, mark)

# --- input --------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()
			_press((event as InputEventMouseButton).position)
		else:
			_release()
		accept_event()
	elif event is InputEventMouseMotion and _mouse_note >= 0:
		var n := note_at((event as InputEventMouseMotion).position)
		if n != _mouse_note:
			_release()
			if n >= 0:
				_press_note(n)
		accept_event()

func _press(pos: Vector2) -> void:
	var n := note_at(pos)
	if n >= 0:
		_press_note(n)

func _press_note(n: int) -> void:
	_mouse_note = n
	note_pressed.emit(n)

func _release() -> void:
	if _mouse_note >= 0:
		var n := _mouse_note
		_mouse_note = -1
		note_released.emit(n)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_release()

func _get_tooltip(at_position: Vector2) -> String:
	var n := note_at(at_position)
	if n < 0:
		return ""
	var t := "%s (MIDI %d)" % [SynthRackStyle.note_name(n), n]
	if played.has(n):
		t += "\nThe game plays this note at velocity %.2f." % float(played[n])
	return t
