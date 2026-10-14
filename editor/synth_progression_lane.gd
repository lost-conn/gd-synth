@tool
class_name SynthProgressionLane
extends Control

# The strip across the top of the Track view: one chip per MusicBlock, as wide as
# the block is long, drawn on the timeline the track lanes share. The progression
# repeats to fill the timeline; only the first trip is live, the repeats are
# dimmed copies. A click selects a block (the view edits it below).

signal block_selected(index: int)

var timeline: SynthTimeline
var selected: int = -1:
	set(v):
		selected = v
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

## Rect of block [param i] in the first trip.
func block_rect(i: int) -> Rect2:
	for e in timeline.block_starts():
		if e[1] == i:
			return _chip_rect(e)
	return Rect2()

func _chip_rect(e: Array) -> Rect2:
	var s := SynthRackStyle.scale(self)
	var b: MusicBlock = e[2]
	var x0 := timeline.x_of(e[0], size.x)
	var x1 := timeline.x_of(minf(e[0] + float(maxi(1, b.duration_beats)), timeline.span), size.x)
	return Rect2(x0 + 1.0, 3.0 * s, maxf(2.0, x1 - x0 - 2.0), size.y - 6.0 * s)

func _block_at(pos: Vector2) -> int:
	if timeline == null:
		return -1
	for e in timeline.block_starts():
		if _chip_rect(e).has_point(pos):
			return e[1]
	return -1

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		var i := _block_at(mb.position)
		if i >= 0:
			selected = i
			block_selected.emit(i)
			accept_event()

func _get_tooltip(at_position: Vector2) -> String:
	var i := _block_at(at_position)
	if i < 0 or timeline == null or timeline.data == null:
		return ""
	var b: MusicBlock = timeline.data.blocks[i]
	return "Block %d: %s chord, %s scale (%s), %d beats.\nClick to edit." % [i + 1, SynthHarmony.chord_name(b),
			SynthHarmony.NOTE_NAMES[posmod(b.scale_root, 12)], SynthHarmony.scale_name(b.scale_intervals), b.duration_beats]

func _draw() -> void:
	var s := SynthRackStyle.scale(self)
	draw_rect(Rect2(Vector2.ZERO, size), SynthRackStyle.inset(self))
	if timeline == null or timeline.data == null or timeline.data.blocks.is_empty():
		draw_string(SynthRackStyle.font(self), Vector2(8.0 * s, size.y * 0.5 + 5.0 * s), "No progression.",
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0 * s, SynthRackStyle.font_size(self), SynthRackStyle.dim(self))
		return
	var font := SynthRackStyle.font(self)
	var big := SynthRackStyle.font_size(self, 1.1)
	var small := SynthRackStyle.font_size(self, 0.8)
	var accent := SynthRackStyle.accent(self)
	var trip := timeline.progression_beats()
	for e in timeline.block_starts():
		var b: MusicBlock = e[2]
		var r := _chip_rect(e)
		var repeat: bool = e[0] >= trip - 0.0001
		var c := chip_color(b)
		c.a = 0.40 if repeat else 0.95
		draw_rect(r, c)
		if e[1] == selected:
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
