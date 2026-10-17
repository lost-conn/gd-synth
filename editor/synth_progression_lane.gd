@tool
class_name SynthProgressionLane
extends Control

# The strip across the top of the Track view: one chip per MusicBlock, as wide as
# the block is long, drawn on the timeline the track lanes share. The progression
# repeats to fill the timeline; only the first trip is live, the repeats are
# dimmed copies. A click selects a block (the view edits it below).
#
# With a song on the timeline it shows each section's own progression end to end,
# the chords under each section as the game plays them: a section's repeats and the
# repeats of an entry are the dimmed copies. A click selects the block and, through
# block_picked, the section it belongs to.

signal block_selected(index: int)
## A block was clicked: [param entry] is the song entry it sits in (-1 without a
## song), [param index] its place in its section's progression.
signal block_picked(entry: int, index: int)

var timeline: SynthTimeline
var selected: int = -1:
	set(v):
		selected = v
		queue_redraw()
## With a song: the progression [member selected] is a block of, since sections can
## have progressions of their own (null: the timeline's data).
var selected_data: MusicData:
	set(v):
		selected_data = v
		queue_redraw()

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true

func _ready() -> void:
	custom_minimum_size.y = 46.0 * SynthRackStyle.scale(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

static func chip_color(b: MusicBlock) -> Color:
	return Color.from_hsv(float(posmod(b.chord_root, 12)) / 12.0, 0.42, 0.56)

## Rect of block [param i] in the first trip. With a song: in the first chip of entry
## [param entry] (the first section that has one when -1).
func block_rect(i: int, entry: int = -1) -> Rect2:
	for e in timeline.block_starts():
		if e[1] == i and (entry < 0 or timeline.song == null or timeline.segments[e[4]]["entry"] == entry):
			return _chip_rect(e)
	return Rect2()

## Every chip drawn, as {rect, index, entry (-1 without a song), repeat (dimmed copy)}.
func chips() -> Array:
	var out: Array = []
	if timeline == null:
		return out
	for e in timeline.block_starts():
		out.append({"rect": _chip_rect(e), "index": e[1], "entry": _entry_of(e), "repeat": _is_repeat(e)})
	return out

func _entry_of(e: Array) -> int:
	return timeline.segments[e[4]]["entry"] if timeline.song != null and e.size() > 4 else -1

func _is_repeat(e: Array) -> bool:
	if timeline.song != null and e.size() > 5:
		return int(timeline.segments[e[4]]["repeat"]) > 0 or int(e[5]) > 0
	return e[0] >= timeline.progression_beats() - 0.0001

func _is_selected(e: Array) -> bool:
	if timeline.song != null and e.size() > 3 and selected_data != null and e[3] != selected_data:
		return false
	return e[1] == selected

func _chip_rect(e: Array) -> Rect2:
	var s := SynthRackStyle.scale(self)
	var b: MusicBlock = e[2]
	var x0 := timeline.x_of(e[0], size.x)
	var x1 := timeline.x_of(minf(e[0] + float(maxi(1, b.duration_beats)), timeline.span), size.x)
	return Rect2(x0 + 1.0, 3.0 * s, maxf(2.0, x1 - x0 - 2.0), size.y - 6.0 * s)

func _chip_at(pos: Vector2) -> Array:
	if timeline == null:
		return []
	for e in timeline.block_starts():
		if _chip_rect(e).has_point(pos):
			return e
	return []

func _block_at(pos: Vector2) -> int:
	var e := _chip_at(pos)
	return e[1] if not e.is_empty() else -1

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		var e := _chip_at(mb.position)
		if not e.is_empty():
			block_picked.emit(_entry_of(e), e[1])
			selected = e[1]
			if timeline.song != null and e.size() > 3:
				selected_data = e[3]
			block_selected.emit(e[1])
			accept_event()

func _get_tooltip(at_position: Vector2) -> String:
	var e := _chip_at(at_position)
	if e.is_empty():
		return ""
	var i: int = e[1]
	var b: MusicBlock = e[2]
	var of := ""
	if timeline.song != null and e.size() > 4:
		of = " of %s" % SynthSongLayout.section_label(timeline.segments[e[4]]["section"])
	return "Block %d%s: %s chord, %s scale (%s), %d beats.\nClick to edit." % [i + 1, of, SynthHarmony.chord_name(b),
			SynthHarmony.NOTE_NAMES[posmod(b.scale_root, 12)], SynthHarmony.scale_name(b.scale_intervals), b.duration_beats]

func _draw() -> void:
	var s := SynthRackStyle.scale(self)
	draw_rect(Rect2(Vector2.ZERO, size), SynthRackStyle.inset(self))
	if timeline == null or timeline.block_starts().is_empty():
		draw_string(SynthRackStyle.font(self), Vector2(8.0 * s, size.y * 0.5 + 5.0 * s), "No progression.",
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0 * s, SynthRackStyle.font_size(self), SynthRackStyle.dim(self))
		return
	var font := SynthRackStyle.font(self)
	var big := SynthRackStyle.font_size(self, 1.1)
	var small := SynthRackStyle.font_size(self, 0.8)
	var accent := SynthRackStyle.accent(self)
	for e in timeline.block_starts():
		var b: MusicBlock = e[2]
		var r := _chip_rect(e)
		var repeat := _is_repeat(e)
		var c := chip_color(b)
		c.a = 0.40 if repeat else 0.95
		draw_rect(r, c)
		if _is_selected(e):
			draw_rect(r, accent if not repeat else Color(accent, 0.4), false, 2.0 * s)
		if r.size.x < 18.0 * s:
			continue
		var fg := Color(1, 1, 1, 0.5 if repeat else 1.0)
		draw_string(font, Vector2(r.position.x + 6.0 * s, r.position.y + 17.0 * s), SynthHarmony.chord_name(b),
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8.0 * s, big, fg)
		if r.size.x > 54.0 * s:
			draw_string(font, Vector2(r.position.x + 6.0 * s, r.end.y - 6.0 * s),
					"%s %s  %d" % [SynthHarmony.NOTE_NAMES[posmod(b.scale_root, 12)], SynthHarmony.scale_name(b.scale_intervals), b.duration_beats],
					HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8.0 * s, small, Color(fg, fg.a * 0.8))
