@tool
class_name SynthClipLane
extends Control

# The right-hand half of a track lane: the track's pattern drawn as a clip that
# repeats at the pattern's length across the timeline, each clip with a small
# picture of its notes (one tick per note, higher pitch higher up). Block
# boundaries run behind it. The picture is cached; nothing here redraws while the
# song plays (the playhead is a layer of its own).

signal pressed
signal clip_activated

var timeline: SynthTimeline
var pattern: MusicPattern
var track_type: int = MusicTrack.TrackType.CHORD
var color: Color = Color(0.5, 0.7, 1.0)
var clip_name: String = ""
var selected: bool = false:
	set(v):
		selected = v
		queue_redraw()
var audible: bool = true:
	set(v):
		audible = v
		queue_redraw()

# [beat, duration, 0..1 height (1 = highest)]
var _ticks: Array = []

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true

func _ready() -> void:
	custom_minimum_size.y = 52.0 * SynthRackStyle.scale(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

## (Re)read the pattern into the note picture. Call after anything about the
## pattern or the track's type changed.
func rebuild() -> void:
	_ticks.clear()
	if pattern != null and not pattern.notes.is_empty():
		var block: MusicBlock = timeline.data.blocks[0] if timeline != null and timeline.data != null and not timeline.data.blocks.is_empty() else null
		var rpo := SynthPitchMap.rows_per_octave(track_type, block)
		var lo := 1 << 30
		var hi := -(1 << 30)
		var rows: Array = []
		for n in pattern.notes:
			var r := SynthPitchMap.display_row(track_type, n.index, n.octave, rpo)
			rows.append(r)
			lo = mini(lo, r)
			hi = maxi(hi, r)
		for i in pattern.notes.size():
			var n: PatternNote = pattern.notes[i]
			var h := 0.5 if hi == lo else float(rows[i] - lo) / float(hi - lo)
			_ticks.append([n.beat, n.duration, h])
	queue_redraw()

## Rect of the first clip, for tests and hit-testing.
func clip_rect(repeat: int = 0) -> Rect2:
	var s := SynthRackStyle.scale(self)
	if pattern == null or pattern.length_beats <= 0.0 or timeline == null:
		return Rect2()
	var start := float(repeat) * pattern.length_beats
	var x0 := timeline.x_of(start, size.x)
	var x1 := timeline.x_of(minf(start + pattern.length_beats, timeline.span), size.x)
	return Rect2(x0 + 1.0, 4.0 * s, maxf(2.0, x1 - x0 - 2.0), size.y - 8.0 * s)

func _clip_at(pos: Vector2) -> bool:
	if pattern == null or pattern.length_beats <= 0.0 or timeline == null:
		return false
	var reps := int(ceilf(timeline.span / pattern.length_beats - 0.0001))
	var rep := int(floorf(timeline.beat_of(pos.x, size.x) / pattern.length_beats))
	return rep >= 0 and rep < reps and clip_rect(rep).has_point(pos)

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit()
		if mb.double_click and _clip_at(mb.position):
			clip_activated.emit()
		accept_event()

func _get_tooltip(at_position: Vector2) -> String:
	if pattern == null:
		return "This track has no pattern."
	if _clip_at(at_position):
		return "%s: %s beats, %d notes, repeating.\nDouble-click to edit it in Pattern." % [clip_name, pattern.length_beats, pattern.notes.size()]
	return ""

func _draw() -> void:
	var s := SynthRackStyle.scale(self)
	draw_rect(Rect2(Vector2.ZERO, size), SynthRackStyle.inset(self))
	if timeline == null:
		return
	var grid := SynthRackStyle.grid(self)
	var ppb := size.x / maxf(timeline.span, 0.001)
	if ppb >= 7.0 * s:
		for b in int(ceilf(timeline.span)):
			var x := timeline.x_of(float(b), size.x)
			draw_line(Vector2(x, 0), Vector2(x, size.y), Color(grid, grid.a * 0.5), 1.0)
	for e in timeline.block_starts():
		var x: float = timeline.x_of(e[0], size.x)
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(grid, grid.a * 2.2), 1.0)
	var font := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.8)
	if pattern == null or pattern.length_beats <= 0.0:
		draw_string(font, Vector2(8.0 * s, size.y * 0.5 + 4.0 * s), "no pattern",
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0 * s, fs, SynthRackStyle.dim(self))
	else:
		var alpha := 1.0 if audible else 0.35
		var reps := int(ceilf(timeline.span / pattern.length_beats - 0.0001))
		for rep in reps:
			var r := clip_rect(rep)
			draw_rect(r, Color(color, 0.22 * alpha))
			draw_rect(r, Color(color, 0.85 * alpha), false, 1.0)
			var inner := r.grow(-3.0 * s)
			var nh := clampf(inner.size.y / 12.0, 2.0, 4.0 * s)
			var start := float(rep) * pattern.length_beats
			for t in _ticks:
				var bx: float = timeline.x_of(start + t[0], size.x)
				if bx >= r.end.x - 0.5:
					continue
				var w := minf(maxf(1.0, t[1] * ppb), r.end.x - bx - 1.0)
				var y: float = inner.position.y + (1.0 - t[2]) * (inner.size.y - nh)
				draw_rect(Rect2(bx, y, maxf(1.0, w), nh), Color(color.lightened(0.25), 0.95 * alpha))
			if r.size.x > 60.0 * s:
				draw_string(font, Vector2(r.position.x + 4.0 * s, r.position.y + fs + 1.0 * s), clip_name,
						HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8.0 * s, fs, Color(1, 1, 1, 0.75 * alpha))
	if selected:
		draw_rect(Rect2(Vector2.ZERO, size), SynthRackStyle.accent(self), false, 2.0 * s)
