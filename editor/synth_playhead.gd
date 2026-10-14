@tool
class_name SynthPlayhead
extends Control

# The yellow playback cursor, drawn over the roll and the velocity lane. It is a
# layer of its own so that while the preview plays only this layer repaints (and
# only when the cursor has moved a pixel), not the notes underneath.

var roll: SynthRoll
var lane: Control
var director: MusicDirector:
	set(value):
		director = value
		set_process(value != null)
		_last_x = -1.0
		queue_redraw()

var _last_x: float = -1.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

## The cursor's x in this control's space, or -1 when it is not on show.
func current_x() -> float:
	if director == null or roll == null or roll.pattern == null or roll.pattern.length_beats <= 0.0:
		return -1.0
	var total := director.get_total_beats()
	if not director.playing and total < 0.001:
		return -1.0
	var x := roll.beat_to_x(fposmod(total, roll.pattern.length_beats))
	var a := roll.get_area()
	if x < a.position.x or x > a.end.x:
		return -1.0
	return x

func _process(_delta: float) -> void:
	var x := roundf(current_x())
	if x != _last_x:
		_last_x = x
		queue_redraw()

func _draw() -> void:
	var x := current_x()
	if x < 0.0 or roll == null:
		return
	var s := SynthRackStyle.scale(self)
	var col := Color(1.0, 0.88, 0.25, 0.95)
	var a := roll.get_area()
	draw_line(Vector2(x, a.position.y), Vector2(x, a.end.y), col, 2.0 * s)
	var rh := roll.get_ruler_height()
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - 6.0 * s, 1.0), Vector2(x + 6.0 * s, 1.0), Vector2(x, rh - 2.0 * s)]), col)
	if lane != null and lane.visible:
		draw_line(Vector2(x, lane.position.y), Vector2(x, lane.position.y + lane.size.y), col, 2.0 * s)
