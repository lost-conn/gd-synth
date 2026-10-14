@tool
class_name SynthVelocityLane
extends Control

# The strip under the roll: one bar per note, as tall as its velocity, on the
# roll's time axis. Drag a bar to set it; drag across several to paint them (the
# value is followed along the line the mouse travelled, so a fast sweep still
# makes a clean ramp). With notes selected only they are painted; with none
# selected, every note is.

var roll: SynthRoll

var _painting: bool = false
var _last: Vector2

func setup(r: SynthRoll) -> void:
	roll = r
	roll.view_changed.connect(queue_redraw)
	roll.selection_changed.connect(queue_redraw)
	roll.pattern_edited.connect(queue_redraw)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	clip_contents = true
	tooltip_text = "Velocity. Drag a bar to set it, or drag across bars to paint them.\nOnly the selected notes are painted when any are selected."

func _ready() -> void:
	custom_minimum_size = Vector2(0, 72.0 * SynthRackStyle.scale(self))

func _plot() -> Rect2:
	var s := SynthRackStyle.scale(self)
	var a := roll.get_area()
	return Rect2(a.position.x, 6.0 * s, a.size.x, size.y - 12.0 * s)

func _bar(n: PatternNote) -> Rect2:
	var s := SynthRackStyle.scale(self)
	var plot := _plot()
	var x := roll.beat_to_x(n.beat)
	var w := clampf(n.duration * roll.beat_width, 4.0 * s, 10.0 * s)
	var h := plot.size.y * clampf(n.velocity, 0.0, 1.0)
	return Rect2(x, plot.end.y - h, w, h)

func _draw() -> void:
	if roll == null or roll.pattern == null:
		return
	var s := SynthRackStyle.scale(self)
	var plot := _plot()
	var inset := SynthRackStyle.inset(self)
	var card := SynthRackStyle.card_bg(self)
	var dim := SynthRackStyle.dim(self)
	var grid := SynthRackStyle.grid(self)
	var accent := SynthRackStyle.accent(self)
	var gold := SynthRackStyle.marker(self)
	var font := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.8)
	draw_rect(Rect2(Vector2.ZERO, size), inset)
	for q in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var y: float = plot.end.y - plot.size.y * q
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(grid, grid.a * (1.4 if q == 0.5 else 0.7)), 1.0)
	var sel := roll.get_selected()
	for pass_i in 2:
		for n in roll.pattern.notes:
			var is_sel: bool = sel.has(n)
			if is_sel != (pass_i == 1):
				continue
			var r := _bar(n)
			if r.end.x < plot.position.x or r.position.x > plot.end.x:
				continue
			var c: Color = gold if is_sel else accent
			c.a = 0.95 if (is_sel or sel.is_empty()) else 0.55
			r = r.intersection(Rect2(plot.position.x, 0, plot.size.x, size.y))
			draw_rect(r, c)
			draw_rect(Rect2(r.position.x, r.position.y, r.size.x, maxf(2.0, 2.0 * s)), Color(1, 1, 1, 0.55))
	var gw := roll.get_gutter_width()
	draw_rect(Rect2(0, 0, gw, size.y), card)
	draw_line(Vector2(gw, 0), Vector2(gw, size.y), SynthRackStyle.card_border(self), 1.0)
	draw_string(font, Vector2(6.0 * s, plot.position.y + fs), "Velocity", HORIZONTAL_ALIGNMENT_LEFT, gw - 8.0 * s, fs, dim)
	draw_string(font, Vector2(6.0 * s, plot.end.y), "0", HORIZONTAL_ALIGNMENT_LEFT, gw - 8.0 * s, fs, dim)
	draw_string(font, Vector2(6.0 * s, plot.position.y + plot.size.y * 0.5 + fs * 0.4), "0.5", HORIZONTAL_ALIGNMENT_LEFT, gw - 8.0 * s, fs, dim)

func _gui_input(event: InputEvent) -> void:
	if roll == null or roll.pattern == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.position.x < roll.get_area().position.x:
					return
				roll.grab_focus()
				roll.begin_edit()
				_painting = true
				_last = mb.position
				_paint(mb.position, mb.position)
			elif _painting:
				_painting = false
				roll.end_edit("Paint velocity")
	elif event is InputEventMouseMotion and _painting:
		var pos := (event as InputEventMouseMotion).position
		_paint(_last, pos)
		_last = pos

# Set the velocity of every candidate bar the mouse passed between [param a] and [param b].
func _paint(a: Vector2, b: Vector2) -> void:
	var plot := _plot()
	var sel := roll.get_selected()
	var lo := minf(a.x, b.x)
	var hi := maxf(a.x, b.x)
	var changed := false
	for n in roll.pattern.notes:
		if not sel.is_empty() and not sel.has(n):
			continue
		var r := _bar(n)
		var pad := 3.0 * SynthRackStyle.scale(self)
		if r.end.x + pad < lo or r.position.x - pad > hi:
			continue
		if r.end.x < plot.position.x or r.position.x > plot.end.x:
			continue
		var cx := clampf(r.position.x + r.size.x * 0.5, lo, hi)
		var y := b.y if is_equal_approx(a.x, b.x) else lerpf(a.y, b.y, (cx - a.x) / (b.x - a.x))
		var v := snappedf(clampf(1.0 - (y - plot.position.y) / plot.size.y, 0.0, 1.0), 0.01)
		if not is_equal_approx(n.velocity, v):
			n.velocity = v
			changed = true
	if changed:
		roll.notify_live_edit()
