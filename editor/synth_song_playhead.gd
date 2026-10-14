@tool
class_name SynthSongPlayhead
extends Control

# The yellow cursor across the ruler, the progression and every lane. A layer of
# its own, so that while the song plays only this repaints, and only when the
# cursor has moved a pixel.

var timeline: SynthTimeline
## Left edge and width of the area the beats map onto, in this control's space.
var area_x: float = 0.0
var area_w: float = 1.0
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

## The cursor's x, or -1 when it is not on show.
func current_x() -> float:
	if director == null or timeline == null or timeline.span <= 0.0:
		return -1.0
	var total := director.get_total_beats()
	if not director.playing and total < 0.001:
		return -1.0
	return area_x + timeline.x_of(fposmod(total, timeline.span), area_w)

func _process(_delta: float) -> void:
	var x := roundf(current_x())
	if x != _last_x:
		_last_x = x
		queue_redraw()

func _draw() -> void:
	var x := current_x()
	if x < 0.0:
		return
	var s := SynthRackStyle.scale(self)
	var col := Color(1.0, 0.88, 0.25, 0.95)
	draw_line(Vector2(x, 0), Vector2(x, size.y), col, 2.0 * s)
