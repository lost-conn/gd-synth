@tool
class_name SynthSongRuler
extends Control

# The beat ruler above the track lanes. Click or drag on it to move the playhead.

signal seek_requested(beat: float)

const BEATS_PER_BAR := 4

var timeline: SynthTimeline

var _dragging: bool = false

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSPLIT
	clip_contents = true
	tooltip_text = "Click or drag to move the playhead."

func _ready() -> void:
	custom_minimum_size.y = 20.0 * SynthRackStyle.scale(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if timeline == null:
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_dragging = mb.pressed
		if mb.pressed:
			seek_requested.emit(timeline.beat_of(mb.position.x, size.x))
			accept_event()
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging:
		seek_requested.emit(timeline.beat_of(mm.position.x, size.x))
		accept_event()

func _draw() -> void:
	var s := SynthRackStyle.scale(self)
	draw_rect(Rect2(Vector2.ZERO, size), SynthRackStyle.card_bg(self))
	if timeline == null:
		return
	var font := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.8)
	var dim := SynthRackStyle.dim(self)
	var grid := SynthRackStyle.grid(self)
	var ppb := size.x / maxf(timeline.span, 0.001)
	var beats := int(ceilf(timeline.span))
	for b in beats + 1:
		var x := timeline.x_of(float(b), size.x)
		var bar: bool = b % BEATS_PER_BAR == 0
		if not bar and ppb < 6.0 * s:
			continue
		var h := size.y * (0.7 if bar else 0.3)
		draw_line(Vector2(x, size.y - h), Vector2(x, size.y), Color(grid, grid.a * 2.0 if bar else grid.a), 1.0)
		if bar and b < beats and ppb * BEATS_PER_BAR > 22.0 * s:
			draw_string(font, Vector2(x + 3.0 * s, fs + 2.0 * s), str(b / BEATS_PER_BAR + 1),
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim)
