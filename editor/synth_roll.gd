@tool
class_name SynthRoll
extends Control

# The Pattern view's piano roll: a beat ruler, a row gutter, a scrollable and
# zoomable grid of notes and pitch bends, and the playback cursor's x for the
# overlay that draws it. It edits the MusicPattern in place while a gesture is
# under way and reports each finished gesture through `edit_committed` with a
# snapshot of how it started, so the owner can record one undo action for it
# (a drag is one action however long it was).
#
# Rows
#   What a row means depends on `track_type` (chord-tone index, scale degree,
#   absolute MIDI note) and the roll shows every row from `row_lo` to `row_hi`.
#   That range grows to include every note and bend, with a margin, so nothing
#   is ever off the grid; it never shrinks while a gesture is under way, so the
#   rows do not slide under the mouse.
#
# Mouse
#   click empty        draw a note (drag sideways to set its length)
#   drag a note        move it (all selected notes move together)
#   drag a note's end  resize it
#   Ctrl + drag        marquee select; also Alt + drag (a window manager may
#                      take Alt for itself). Shift adds to the selection
#   Shift + drag       marquee that adds to the selection
#   Shift + click      on a note: add / remove it; on empty: clear the selection
#   right click        delete the note or bend under the mouse
#   click a bend       select it; drag its tip (glide + target), or its start
#                      (offset) once selected
#   ruler click / drag seek the preview
#   gutter click       audition that row
#   wheel              scroll rows
#   Ctrl + wheel       zoom time        (as Godot's animation editor)
#   Shift/Alt + wheel  zoom rows        (as Godot's curve editors' vertical zoom)
#   wheel left / right, middle drag, scrollbars   scroll time
#
# Keys (with the roll focused)
#   arrows nudge by one snap step / one row; Shift + Up / Down moves an octave
#   Delete  Ctrl+C / X / V / D / A   delete, copy, cut, paste, duplicate, all
#   B       add a bend to the selected note, aimed at the mouse row

## The selection changed (notes or bend).
signal selection_changed
## Data changed during a gesture, or in a finished one: refresh readouts.
signal pattern_edited
## A gesture finished. [param before] is the pattern as it was when it began.
signal edit_committed(label: String, before: SynthPatternSnapshot)
## A note was created or moved to a new row: play it.
signal note_auditioned(note: PatternNote)
## The gutter was clicked at [param row].
signal row_auditioned(row: int)
## The ruler was clicked or dragged at [param beat] (pattern beats).
signal seek_requested(beat: float)
## Zoom, scroll or the row range changed: things drawn in step with the roll follow.
signal view_changed

enum Drag { IDLE, CREATING, MOVING, RESIZING, MARQUEE, SEEKING, BEND_TIP, BEND_START, PANNING }

const MIN_BEAT_W := 6.0
const MAX_BEAT_W := 480.0
const OPEN_BEAT_W := 36.0
const MIN_ROW_H := 9.0
const MAX_ROW_H := 44.0
const ACCIDENTAL_SHIFT := 0.25   # fraction of a row per semitone
const INDEX_MIN := -64
const INDEX_MAX := 127
const ROW_MARGIN := 2

var pattern: MusicPattern:
	set(value):
		pattern = value
		_selected.clear()
		_clear_bend_selection()
		_drag = Drag.IDLE
		_edit_before = null
		_range_set = false
		_recompute_range()
		_pending_fit = true
		_pending_center = true
		_layout()
		selection_changed.emit()
		queue_redraw()

## Show the pattern without letting it be edited: seeking, scrolling and zooming
## work; nothing creates, moves, deletes or selects a note. The Pattern view sets
## it when the pattern is a PatternChain, whose notes are drawn from a flattened
## copy.
var read_only: bool = false

var track_type: int = MusicTrack.TrackType.CHORD:
	set(value):
		if value == track_type:
			return
		track_type = value
		_range_set = false
		_recompute_range()
		_pending_center = true
		_layout()
		queue_redraw()
		view_changed.emit()

## Rows per octave of the chord / scale (3 and 7 unless the progression says otherwise).
var rows_per_octave: int = 3:
	set(value):
		value = maxi(1, value)
		if value == rows_per_octave:
			return
		rows_per_octave = value
		_recompute_range()
		queue_redraw()
		view_changed.emit()

## Snap step in beats (1/4 = a quarter of a beat).
var snap_step: float = 0.25:
	set(value):
		snap_step = maxf(0.001, value)
		queue_redraw()

var beat_width: float = 60.0
var row_height: float = 18.0
var row_lo: int = -3
var row_hi: int = 8
var scroll_x: float = 0.0
var scroll_y: float = 0.0

## Faint notes of other tracks: [{beat, dur, row, color, vel}].
var faint: Array = []

var _selected: Array = []
var _sel_bend: PatternBend
var _sel_bend_parent: Array = []
var _sel_bend_note: PatternNote
var _clipboard: Array = []
var _drag: int = Drag.IDLE
var _drag_note: PatternNote
var _drag_start: Vector2
var _drag_origin: Dictionary = {}
var _drag_row_delta: int = 0
var _bend_entry: Dictionary = {}
var _marquee_anchor: Vector2
var _marquee_add: bool = false
## False for a Shift press on empty until the mouse moves past a click's slop:
## a bare Shift click clears the selection, Shift + drag is a marquee.
var _marquee_live: bool = true
var _pan_scroll: Vector2
var _edit_before: SynthPatternSnapshot
var _mouse: Vector2 = Vector2(-1, -1)
var _mouse_inside: bool = false
var _range_set: bool = false
var _pending_fit: bool = true
var _pending_center: bool = true
var _area: Rect2 = Rect2(0, 0, 100, 100)
var _hbar: HScrollBar
var _vbar: VScrollBar
var _font: Font
var _fs: int = 12

func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_hbar = HScrollBar.new()
	_hbar.value_changed.connect(_on_hbar)
	add_child(_hbar)
	_vbar = VScrollBar.new()
	_vbar.value_changed.connect(_on_vbar)
	add_child(_vbar)

func _ready() -> void:
	custom_minimum_size = Vector2(200.0 * _s(), 150.0 * _s())
	row_height = 18.0 * _s()
	_font = SynthRackStyle.font(self)
	_fs = SynthRackStyle.font_size(self, 0.85)
	_recompute_range()
	_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()
	elif what == NOTIFICATION_THEME_CHANGED:
		_font = SynthRackStyle.font(self)
		_fs = SynthRackStyle.font_size(self, 0.85)
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_ENTER:
		_mouse_inside = true
	elif what == NOTIFICATION_MOUSE_EXIT:
		_mouse_inside = false

func _s() -> float:
	return SynthRackStyle.scale(self)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_selected() -> Array:
	return _selected.duplicate()

func get_selected_bend() -> Dictionary:
	if _sel_bend == null:
		return {}
	for e in _flat_bends():
		if e["bend"] == _sel_bend:
			return e
	return {}

func select_notes(notes: Array) -> void:
	_selected = notes.duplicate()
	_clear_bend_selection()
	selection_changed.emit()
	queue_redraw()

func clear_selection() -> void:
	_selected.clear()
	_clear_bend_selection()
	selection_changed.emit()
	queue_redraw()

func select_bend(bend: PatternBend) -> void:
	for e in _flat_bends():
		if e["bend"] == bend:
			_select_bend(e)
			return

## The grid area (excluding gutter, ruler and scrollbars), in this control's space.
func get_area() -> Rect2:
	return _area

func get_gutter_width() -> float:
	return (112.0 if track_type == MusicTrack.TrackType.DRUM else 64.0) * _s()

func get_ruler_height() -> float:
	return 22.0 * _s()

func beat_to_x(beat: float) -> float:
	return _area.position.x + beat * beat_width - scroll_x

func x_to_beat(x: float) -> float:
	return (x - _area.position.x + scroll_x) / beat_width

func row_to_y(row: int) -> float:
	return _area.position.y + float(row_hi - row) * row_height - scroll_y

func y_to_row(y: float) -> int:
	return row_hi - floori((y - _area.position.y + scroll_y) / row_height)

func snap_beat(b: float) -> float:
	return roundf(b / snap_step) * snap_step

## The row a note is drawn on.
func row_of(index: int, octave: int) -> int:
	return SynthPitchMap.display_row(track_type, index, octave, rows_per_octave)

## The rectangle of [param n] in this control's space.
func note_rect(n: PatternNote) -> Rect2:
	var y := row_to_y(row_of(n.index, n.octave))
	if track_type != MusicTrack.TrackType.DRUM:
		y -= n.accidental * row_height * ACCIDENTAL_SHIFT
	return Rect2(beat_to_x(n.beat), y + 1.0, maxf(3.0, n.duration * beat_width), row_height - 2.0)

func set_faint(list: Array) -> void:
	faint = list
	queue_redraw()

## Bring the roll in line with the pattern after it changed from outside (an undo,
## the Godot inspector): drop selections that no longer exist, regrow the rows.
func refresh() -> void:
	if pattern != null:
		var keep: Array = []
		for n in _selected:
			if pattern.notes.has(n):
				keep.append(n)
		var changed := keep.size() != _selected.size()
		_selected = keep
		if _sel_bend != null and (not pattern.notes.has(_sel_bend_note) or not _sel_bend_parent.has(_sel_bend)):
			_clear_bend_selection()
			changed = true
		if changed:
			selection_changed.emit()
	_recompute_range()
	_layout()
	queue_redraw()

## Fit the whole pattern into the width. A newly opened pattern is only fitted
## down to [constant OPEN_BEAT_W] px per beat (a long pattern then scrolls, rather
## than opening as a smear); the Fit button asks for the whole thing.
func zoom_fit(whole: bool = true) -> void:
	if pattern == null or _area.size.x < 40.0:
		_pending_fit = true
		return
	_pending_fit = false
	var avail := _area.size.x - 24.0 * _s()
	var lowest := MIN_BEAT_W if whole else OPEN_BEAT_W * _s()
	beat_width = clampf(avail / maxf(pattern.length_beats, 1.0), lowest, 120.0 * _s())
	_layout()
	queue_redraw()
	view_changed.emit()

## Scroll so the notes (or the middle of the default range) are in view.
func center_rows() -> void:
	if _area.size.y < 20.0:
		_pending_center = true
		return
	_pending_center = false
	var lo := row_hi
	var hi := row_lo
	if pattern != null:
		for n in pattern.notes:
			var r := row_of(n.index, n.octave)
			lo = mini(lo, r)
			hi = maxi(hi, r)
	if lo > hi:
		lo = (row_lo + row_hi) / 2
		hi = lo
	var mid := (lo + hi) * 0.5
	scroll_y = (float(row_hi) - mid + 0.5) * row_height - _area.size.y * 0.5
	_layout()
	queue_redraw()
	view_changed.emit()

func zoom_x(factor: float, anchor_x: float) -> void:
	var anchor := x_to_beat(anchor_x)
	beat_width = clampf(beat_width * factor, MIN_BEAT_W, MAX_BEAT_W)
	scroll_x = anchor * beat_width - (anchor_x - _area.position.x)
	_layout()
	queue_redraw()
	view_changed.emit()

func zoom_y(factor: float, anchor_y: float) -> void:
	var s := _s()
	var anchor_rows := (anchor_y - _area.position.y + scroll_y) / row_height
	row_height = clampf(row_height * factor, MIN_ROW_H * s, MAX_ROW_H * s)
	scroll_y = anchor_rows * row_height - (anchor_y - _area.position.y)
	_layout()
	queue_redraw()
	view_changed.emit()

# ---------------------------------------------------------------------------
# Rows, layout, scrolling
# ---------------------------------------------------------------------------

func _default_range() -> Vector2i:
	match track_type:
		MusicTrack.TrackType.CHORD:
			return Vector2i(-rows_per_octave, rows_per_octave * 3 - 1)
		MusicTrack.TrackType.MELODY:
			return Vector2i(-rows_per_octave, rows_per_octave * 2)
	return Vector2i(35, 52)

# Widen the row range to hold every note and bend (with a margin). [param
# grow_only]: during a gesture, never narrow it.
func _recompute_range(grow_only: bool = false) -> void:
	var d := _default_range()
	var lo := d.x
	var hi := d.y
	if pattern != null:
		for n in pattern.notes:
			var r := row_of(n.index, n.octave)
			lo = mini(lo, r - ROW_MARGIN)
			hi = maxi(hi, r + ROW_MARGIN)
			for e in _bend_rows(n.bends):
				lo = mini(lo, e - ROW_MARGIN)
				hi = maxi(hi, e + ROW_MARGIN)
	if grow_only and _range_set:
		lo = mini(lo, row_lo)
		hi = maxi(hi, row_hi)
	if _range_set and lo == row_lo and hi == row_hi:
		return
	if _range_set:
		# Keep what is on screen where it is.
		scroll_y += float(hi - row_hi) * row_height
	_range_set = true
	row_lo = lo
	row_hi = hi
	_layout()
	view_changed.emit()

func _bend_rows(bends: Array) -> Array:
	var out: Array = []
	for b in bends:
		out.append(row_of(b.index, b.octave))
		out.append_array(_bend_rows(b.bends))
	return out

func _content_size() -> Vector2:
	var length := pattern.length_beats if pattern != null else 4.0
	return Vector2(length * beat_width + 32.0 * _s(), float(row_hi - row_lo + 1) * row_height)

func _layout() -> void:
	if _hbar == null:
		return
	var gw := get_gutter_width()
	var rh := get_ruler_height()
	var bw := _vbar.get_combined_minimum_size().x
	var bh := _hbar.get_combined_minimum_size().y
	var content := _content_size()
	var need_h := false
	var need_v := false
	for i in 2:
		var aw := size.x - gw - (bw if need_v else 0.0)
		var ah := size.y - rh - (bh if need_h else 0.0)
		need_h = content.x > aw + 0.5
		need_v = content.y > ah + 0.5
	_area = Rect2(gw, rh, maxf(0.0, size.x - gw - (bw if need_v else 0.0)),
			maxf(0.0, size.y - rh - (bh if need_h else 0.0)))
	scroll_x = clampf(scroll_x, 0.0, maxf(0.0, content.x - _area.size.x))
	scroll_y = clampf(scroll_y, 0.0, maxf(0.0, content.y - _area.size.y))
	_hbar.visible = need_h
	_vbar.visible = need_v
	_hbar.position = Vector2(gw, size.y - bh)
	_hbar.size = Vector2(_area.size.x, bh)
	_hbar.min_value = 0.0
	_hbar.max_value = content.x
	_hbar.page = _area.size.x
	_hbar.set_value_no_signal(scroll_x)
	_vbar.position = Vector2(size.x - bw, rh)
	_vbar.size = Vector2(bw, _area.size.y)
	_vbar.min_value = 0.0
	_vbar.max_value = content.y
	_vbar.page = _area.size.y
	_vbar.set_value_no_signal(scroll_y)
	if _pending_fit and _area.size.x >= 40.0 and pattern != null:
		zoom_fit(false)
	if _pending_center and _area.size.y >= 20.0:
		center_rows()

func _on_hbar(v: float) -> void:
	scroll_x = v
	queue_redraw()
	view_changed.emit()

func _on_vbar(v: float) -> void:
	scroll_y = v
	queue_redraw()
	view_changed.emit()

func _scroll_by(dx: float, dy: float) -> void:
	scroll_x += dx
	scroll_y += dy
	_layout()
	queue_redraw()
	view_changed.emit()

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	var inset := SynthRackStyle.inset(self)
	draw_rect(Rect2(Vector2.ZERO, size), inset)
	if pattern == null:
		return
	_draw_rows()
	_draw_vgrid()
	_draw_faint()
	_draw_notes()
	_draw_bends()
	if _drag == Drag.MARQUEE and _marquee_live:
		var r := Rect2(_marquee_anchor, _mouse - _marquee_anchor).abs()
		var gold := SynthRackStyle.marker(self)
		draw_rect(r, Color(gold, 0.15))
		draw_rect(r, Color(gold, 0.75), false, 1.0)
	_draw_gutter()
	_draw_ruler()

func _visible_rows() -> Vector2i:
	var top := clampi(y_to_row(_area.position.y), row_lo, row_hi)
	var bottom := clampi(y_to_row(_area.end.y), row_lo, row_hi)
	return Vector2i(bottom, top)

func _is_root_row(row: int) -> bool:
	if track_type == MusicTrack.TrackType.DRUM:
		return posmod(row, 12) == 0
	return posmod(row, rows_per_octave) == 0

func _draw_rows() -> void:
	var accent := SynthRackStyle.accent(self)
	var grid := SynthRackStyle.grid(self)
	var vr := _visible_rows()
	for row in range(vr.x, vr.y + 1):
		var y := row_to_y(row)
		if _is_root_row(row):
			var strong: bool = row == 0 and track_type != MusicTrack.TrackType.DRUM
			draw_rect(Rect2(_area.position.x, y, _area.size.x, row_height), Color(accent, 0.20 if strong else 0.09))
		draw_line(Vector2(_area.position.x, y), Vector2(_area.end.x, y), Color(grid, grid.a * 0.6), 1.0)
	var end_x := beat_to_x(pattern.length_beats)
	if end_x < _area.end.x:
		draw_rect(Rect2(maxf(end_x, _area.position.x), _area.position.y, _area.end.x - maxf(end_x, _area.position.x), _area.size.y), Color(0, 0, 0, 0.28))

func _draw_vgrid() -> void:
	var grid := SynthRackStyle.grid(self)
	var step := snap_step
	if step * beat_width < 5.0:
		step = 1.0
	if step * beat_width < 5.0:
		step = 4.0
	var b0 := maxf(0.0, x_to_beat(_area.position.x))
	var b1 := minf(pattern.length_beats, x_to_beat(_area.end.x))
	var k0 := int(floorf(b0 / step))
	var k1 := int(ceilf(b1 / step))
	var top := _area.position.y
	var bottom := _area.end.y
	for k in range(k0, k1 + 1):
		var b := float(k) * step
		if b < -0.0001 or b > pattern.length_beats + 0.0001:
			continue
		var x := beat_to_x(b)
		if x < _area.position.x - 0.5 or x > _area.end.x + 0.5:
			continue
		var col := Color(grid, grid.a * 0.45)
		var w := 1.0
		if absf(fmod(b, 4.0)) < 0.0001 or absf(fmod(b, 4.0) - 4.0) < 0.0001:
			col = Color(grid, minf(1.0, grid.a * 2.4))
			w = 1.5
		elif absf(b - roundf(b)) < 0.0001:
			col = Color(grid, grid.a * 1.3)
		draw_line(Vector2(x, top), Vector2(x, bottom), col, w)
	var end_x := beat_to_x(pattern.length_beats)
	if end_x >= _area.position.x and end_x <= _area.end.x:
		draw_line(Vector2(end_x, top), Vector2(end_x, bottom), Color(grid, minf(1.0, grid.a * 3.0)), 2.0)

func _draw_faint() -> void:
	if faint.is_empty():
		return
	var b0 := x_to_beat(_area.position.x)
	var b1 := x_to_beat(_area.end.x)
	for f in faint:
		var beat: float = f["beat"]
		var dur: float = f["dur"]
		if beat > b1 or beat + dur < b0:
			continue
		var y := row_to_y(f["row"])
		if y + row_height < _area.position.y or y > _area.end.y:
			continue
		var c: Color = f["color"]
		var r := Rect2(beat_to_x(beat), y + 2.0, maxf(3.0, dur * beat_width), row_height - 4.0)
		r = r.intersection(_area)
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		draw_rect(r, Color(c, 0.22 + 0.15 * float(f["vel"])))
		draw_rect(r, Color(c, 0.5), false, 1.0)

func _draw_notes() -> void:
	var accent := SynthRackStyle.accent(self)
	var gold := SynthRackStyle.marker(self)
	var border := SynthRackStyle.text(self)
	var b0 := x_to_beat(_area.position.x)
	var b1 := x_to_beat(_area.end.x)
	# Unselected first so selected notes sit on top.
	for pass_i in 2:
		for n in pattern.notes:
			var sel: bool = _selected.has(n)
			if sel != (pass_i == 1):
				continue
			if n.beat > b1 or n.beat + n.duration < b0:
				continue
			var r := note_rect(n)
			if r.end.y < _area.position.y or r.position.y > _area.end.y:
				continue
			var fill: Color = gold if sel else accent
			fill.a = lerpf(0.5, 1.0, clampf(n.velocity, 0.0, 1.0))
			var clipped := r.intersection(_area)
			if clipped.size.x <= 0.0 or clipped.size.y <= 0.0:
				continue
			draw_rect(clipped, fill)
			draw_rect(clipped, Color(border, 0.75 if sel else 0.45), false, 1.0)
			if track_type != MusicTrack.TrackType.DRUM and n.accidental != 0.0 and r.size.x > 8.0:
				var sym := "#" if n.accidental > 0.0 else "b"
				draw_string(_font, Vector2(r.position.x + 3.0, r.end.y - 3.0), sym,
						HORIZONTAL_ALIGNMENT_LEFT, r.size.x, _fs, Color(1, 1, 0.55))

func _draw_bends() -> void:
	var s := _s()
	var accent := SynthRackStyle.accent(self)
	var gold := SynthRackStyle.marker(self)
	var good := SynthRackStyle.good(self)
	for e in _flat_bends():
		var is_sel: bool = e["bend"] == _sel_bend
		var col: Color = gold if is_sel else good
		var a: Vector2 = e["start"]
		var t: Vector2 = e["tip"]
		draw_line(a, t, col, 2.0 * s)
		draw_circle(t, 5.0 * s, Color(1, 1, 1, 0.92) if is_sel else col)
		if is_sel:
			draw_circle(t, 5.0 * s, gold, false, 1.5 * s)
			var h := 4.5 * s
			draw_rect(Rect2(a - Vector2(h, h), Vector2(h, h) * 2.0), accent)
			draw_rect(Rect2(a - Vector2(h, h), Vector2(h, h) * 2.0), gold, false, 1.5 * s)

func _draw_gutter() -> void:
	var card := SynthRackStyle.card_bg(self)
	var text := SynthRackStyle.text(self)
	var dim := SynthRackStyle.dim(self)
	var s := _s()
	var gw := get_gutter_width()
	var rh := get_ruler_height()
	draw_rect(Rect2(0, rh, gw, size.y - rh), card)
	draw_line(Vector2(gw, rh), Vector2(gw, size.y), SynthRackStyle.card_border(self), 1.0)
	if row_height < float(_fs) + 2.0:
		return
	var vr := _visible_rows()
	for row in range(vr.x, vr.y + 1):
		var y := row_to_y(row)
		if y + row_height < rh or y > size.y:
			continue
		var root := _is_root_row(row)
		draw_string(_font, Vector2(6.0 * s, y + row_height * 0.5 + float(_fs) * 0.36),
				SynthPitchMap.row_label(track_type, row, rows_per_octave), HORIZONTAL_ALIGNMENT_LEFT,
				gw - 10.0 * s, _fs, text if root else dim)

func _draw_ruler() -> void:
	var s := _s()
	var gw := get_gutter_width()
	var rh := get_ruler_height()
	var card := SynthRackStyle.card_bg(self)
	var text := SynthRackStyle.text(self)
	var dim := SynthRackStyle.dim(self)
	draw_rect(Rect2(0, 0, size.x, rh), card)
	draw_line(Vector2(0, rh), Vector2(size.x, rh), SynthRackStyle.card_border(self), 1.0)
	var every := 1.0 if beat_width >= 26.0 * s else 4.0
	var b0 := maxf(0.0, floorf(x_to_beat(_area.position.x)))
	var b1 := minf(pattern.length_beats, x_to_beat(_area.end.x))
	var b := floorf(b0 / every) * every
	while b <= b1 + 0.0001:
		var x := beat_to_x(b)
		if x >= gw - 0.5 and x <= _area.end.x + 0.5:
			var bar: bool = fmod(b, 4.0) == 0.0
			var tick := rh * (0.65 if bar else 0.35)
			draw_line(Vector2(x, rh - tick), Vector2(x, rh), dim, 1.0)
			draw_string(_font, Vector2(x + 3.0 * s, rh - 7.0 * s), "%d" % int(b), HORIZONTAL_ALIGNMENT_LEFT,
					maxf(10.0, beat_width * every), _fs, text if bar else dim)
		b += every
	draw_rect(Rect2(0, 0, gw, rh), card)
	draw_string(_font, Vector2(6.0 * s, rh - 7.0 * s), "beat", HORIZONTAL_ALIGNMENT_LEFT, gw - 8.0 * s, _fs, dim)

# ---------------------------------------------------------------------------
# Bends
# ---------------------------------------------------------------------------

func _anchor(beat: float, index: int, octave: int, accidental: float) -> Vector2:
	var y := row_to_y(row_of(index, octave)) + row_height * 0.5
	if track_type != MusicTrack.TrackType.DRUM:
		y -= accidental * row_height * ACCIDENTAL_SHIFT
	return Vector2(beat_to_x(beat), y)

# Every bend of every note, parents before their children, with where it is drawn.
func _flat_bends() -> Array:
	var out: Array = []
	if pattern == null:
		return out
	for n in pattern.notes:
		_flat_walk(out, n.beat, n.index, n.octave, n.accidental, n, n.bends)
	return out

func _flat_walk(out: Array, parent_start: float, p_index: int, p_octave: int, p_acc: float,
		note: PatternNote, bends: Array) -> void:
	for b in bends:
		var start_beat: float = parent_start + b.offset_beats
		out.append({
			"bend": b, "parent_array": bends, "note": note, "parent_start": parent_start,
			"start_beat": start_beat,
			"start": _anchor(start_beat, p_index, p_octave, p_acc),
			"tip": _anchor(start_beat + b.glide_beats, b.index, b.octave, b.accidental),
		})
		_flat_walk(out, start_beat, b.index, b.octave, b.accidental, note, b.bends)

## Bend under [param pos]: {entry, part} with part "tip", "start" or "seg"; {} for none.
func _bend_at(pos: Vector2) -> Dictionary:
	var s := _s()
	var flat := _flat_bends()
	for i in range(flat.size() - 1, -1, -1):
		if pos.distance_to(flat[i]["tip"]) <= 6.0 * s:
			return {"entry": flat[i], "part": "tip"}
	if _sel_bend != null:
		for i in range(flat.size() - 1, -1, -1):
			if flat[i]["bend"] == _sel_bend and pos.distance_to(flat[i]["start"]) <= 6.0 * s:
				return {"entry": flat[i], "part": "start"}
	for i in range(flat.size() - 1, -1, -1):
		if _near_segment(pos, flat[i]["start"], flat[i]["tip"], 4.0 * s):
			return {"entry": flat[i], "part": "seg"}
	return {}

static func _near_segment(p: Vector2, a: Vector2, b: Vector2, tol: float) -> bool:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a) <= tol
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t) <= tol

func _select_bend(entry: Dictionary) -> void:
	_selected.clear()
	_sel_bend = entry["bend"]
	_sel_bend_parent = entry["parent_array"]
	_sel_bend_note = entry["note"]
	selection_changed.emit()
	queue_redraw()

func _clear_bend_selection() -> void:
	_sel_bend = null
	_sel_bend_parent = []
	_sel_bend_note = null

## Add a bend to the selected note(s), or a sub-bend to the selected bend, aimed at
## the row under the mouse (two rows up when the mouse is elsewhere).
func add_bend_at_mouse() -> void:
	if pattern == null or read_only:
		return
	var inside := _mouse_inside and _area.has_point(_mouse)
	var step := snap_step
	var made: PatternBend
	begin_edit()
	if _sel_bend != null:
		var e := get_selected_bend()
		if e.is_empty():
			_edit_before = null
			return
		var target_row := y_to_row(_mouse.y) if inside else row_of(_sel_bend.index, _sel_bend.octave) + 2
		if target_row == row_of(_sel_bend.index, _sel_bend.octave):
			target_row += 1
		made = _make_bend(0.0, step, target_row, _sel_bend.octave)
		_sel_bend.bends.append(made)
		_selected.clear()
		end_edit("Add bend")
		var entry := _entry_for(made)
		if not entry.is_empty():
			_select_bend(entry)
		return
	if _selected.is_empty():
		_edit_before = null
		return
	var last: PatternBend
	for n in _selected:
		var note: PatternNote = n
		var parent_row := row_of(note.index, note.octave)
		var row := y_to_row(_mouse.y) if inside else parent_row + 2
		if row == parent_row:
			row += 1
		var off := 0.0
		if inside:
			off = clampf(snap_beat(x_to_beat(_mouse.x)) - note.beat, 0.0, maxf(0.0, note.duration - step))
		last = _make_bend(off, step, row, 0)
		note.bends.append(last)
	end_edit("Add bend")
	var entry2 := _entry_for(last)
	if not entry2.is_empty():
		_select_bend(entry2)

func _make_bend(offset: float, glide: float, row: int, octave: int) -> PatternBend:
	var rpo := rows_per_octave
	var idx := row if track_type == MusicTrack.TrackType.DRUM else row - octave * rpo
	return PatternBend.create(maxf(0.0, offset), glide, clampi(idx, INDEX_MIN, INDEX_MAX), octave, 0.0)

func _entry_for(bend: PatternBend) -> Dictionary:
	for e in _flat_bends():
		if e["bend"] == bend:
			return e
	return {}

func remove_selected_bend() -> void:
	if _sel_bend == null or read_only:
		return
	begin_edit()
	_sel_bend_parent.erase(_sel_bend)
	_clear_bend_selection()
	selection_changed.emit()
	end_edit("Delete bend")

# ---------------------------------------------------------------------------
# Edit gestures
# ---------------------------------------------------------------------------

## Start recording a gesture: the pattern as it is now is what Undo restores.
func begin_edit() -> void:
	if pattern != null and _edit_before == null and not read_only:
		_edit_before = SynthPatternSnapshot.capture(pattern)

## Finish the gesture. If anything changed, [signal edit_committed] fires once.
func end_edit(label: String) -> void:
	var before := _edit_before
	_edit_before = null
	_recompute_range()
	queue_redraw()
	if before == null or pattern == null:
		return
	pattern_edited.emit()
	edit_committed.emit(label, before)

## Data changed in a gesture that is still going on.
func notify_live_edit() -> void:
	queue_redraw()
	pattern_edited.emit()

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_on_key(event as InputEventKey)

func _on_button(ev: InputEventMouseButton) -> void:
	var pos := ev.position
	_mouse = pos
	match ev.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var dir := 1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			var f := ev.factor if ev.factor > 0.0 else 1.0
			if ev.ctrl_pressed or ev.meta_pressed:
				zoom_x(pow(1.15, dir * f), pos.x)
			elif ev.shift_pressed or ev.alt_pressed:
				zoom_y(pow(1.12, dir * f), pos.y)
			else:
				_scroll_by(0.0, -dir * row_height * 3.0 * f)
			accept_event()
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			var d := -1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_LEFT else 1.0
			_scroll_by(d * 60.0 * _s() * (ev.factor if ev.factor > 0.0 else 1.0), 0.0)
			accept_event()
		MOUSE_BUTTON_MIDDLE:
			if ev.pressed:
				_drag = Drag.PANNING
				_drag_start = pos
				_pan_scroll = Vector2(scroll_x, scroll_y)
			elif _drag == Drag.PANNING:
				_drag = Drag.IDLE
		MOUSE_BUTTON_LEFT:
			if ev.pressed:
				grab_focus()
				_press(ev)
			else:
				_end_drag()
		MOUSE_BUTTON_RIGHT:
			if ev.pressed and not read_only and _area.has_point(pos):
				var hit := _bend_at(pos)
				if not hit.is_empty():
					begin_edit()
					hit["entry"]["parent_array"].erase(hit["entry"]["bend"])
					if _sel_bend == hit["entry"]["bend"]:
						_clear_bend_selection()
						selection_changed.emit()
					end_edit("Delete bend")
					return
				var n := _note_at(pos)
				if n != null:
					begin_edit()
					pattern.notes.erase(n)
					_selected.erase(n)
					if _sel_bend_note == n:
						_clear_bend_selection()
					selection_changed.emit()
					end_edit("Delete note")

func _press(ev: InputEventMouseButton) -> void:
	if pattern == null:
		return
	var pos := ev.position
	if pos.y < get_ruler_height() and pos.x >= _area.position.x:
		_drag = Drag.SEEKING
		_seek_to(pos)
		return
	if pos.x < _area.position.x:
		if pos.y >= get_ruler_height():
			row_auditioned.emit(y_to_row(pos.y))
		return
	if read_only or not _area.has_point(pos):
		return
	var hit := _bend_at(pos)
	if not hit.is_empty():
		var entry: Dictionary = hit["entry"]
		_select_bend(entry)
		if hit["part"] == "tip":
			begin_edit()
			_drag = Drag.BEND_TIP
			_bend_entry = entry
		elif hit["part"] == "start":
			begin_edit()
			_drag = Drag.BEND_START
			_bend_entry = entry
		return
	if _sel_bend != null:
		_clear_bend_selection()
		selection_changed.emit()
		queue_redraw()
	var n := _note_at(pos)
	if n != null:
		if ev.shift_pressed:
			if _selected.has(n):
				_selected.erase(n)
			else:
				_selected.append(n)
			selection_changed.emit()
			queue_redraw()
			return
		if _near_right_edge(n, pos):
			_start_resize(n, pos)
		else:
			_start_move(n, pos)
		return
	if ev.alt_pressed or ev.ctrl_pressed or ev.meta_pressed or ev.shift_pressed:
		_drag = Drag.MARQUEE
		_marquee_anchor = pos
		_marquee_add = ev.shift_pressed
		# Shift alone waits to see whether this is a click (clear) or a drag.
		_marquee_live = ev.alt_pressed or ev.ctrl_pressed or ev.meta_pressed
		if not _marquee_add and not _selected.is_empty():
			_selected.clear()
			selection_changed.emit()
		queue_redraw()
		return
	_start_create(pos)

func _on_motion(ev: InputEventMouseMotion) -> void:
	var pos := ev.position
	_mouse = pos
	if _drag == Drag.IDLE:
		_update_cursor(pos)
		return
	match _drag:
		Drag.PANNING:
			scroll_x = _pan_scroll.x - (pos.x - _drag_start.x)
			scroll_y = _pan_scroll.y - (pos.y - _drag_start.y)
			_layout()
			queue_redraw()
			view_changed.emit()
		Drag.MARQUEE:
			if not _marquee_live and pos.distance_to(_marquee_anchor) > 4.0 * _s():
				_marquee_live = true
			queue_redraw()
		Drag.SEEKING:
			_seek_to(pos)
		Drag.BEND_TIP:
			_drag_bend_tip(pos)
		Drag.BEND_START:
			_drag_bend_start(pos)
		Drag.CREATING:
			var n := _drag_note
			var end_beat := maxf(snap_beat(x_to_beat(pos.x)), n.beat + snap_step)
			n.duration = end_beat - n.beat
			notify_live_edit()
		Drag.RESIZING:
			_drag_resize(pos)
		Drag.MOVING:
			_drag_move(pos)

func _update_cursor(pos: Vector2) -> void:
	var shape := Control.CURSOR_ARROW
	if _area.has_point(pos) and pattern != null:
		var hit := _bend_at(pos)
		if not hit.is_empty():
			shape = Control.CURSOR_POINTING_HAND if hit["part"] == "tip" else (Control.CURSOR_HSIZE if hit["part"] == "start" else Control.CURSOR_ARROW)
		else:
			var n := _note_at(pos)
			if n != null and _near_right_edge(n, pos):
				shape = Control.CURSOR_HSIZE
	elif pos.y < get_ruler_height() and pos.x >= _area.position.x:
		shape = Control.CURSOR_HSIZE
	mouse_default_cursor_shape = shape

func _seek_to(pos: Vector2) -> void:
	var beat := clampf(x_to_beat(pos.x), 0.0, maxf(0.0, pattern.length_beats - 0.001))
	seek_requested.emit(beat)

func _note_at(pos: Vector2) -> PatternNote:
	if pattern == null:
		return null
	for i in range(pattern.notes.size() - 1, -1, -1):
		var n: PatternNote = pattern.notes[i]
		if note_rect(n).has_point(pos):
			return n
	return null

func _near_right_edge(n: PatternNote, pos: Vector2) -> bool:
	var r := note_rect(n)
	var margin := minf(6.0 * _s(), r.size.x * 0.4)
	return pos.x > r.end.x - margin

func _end_drag() -> void:
	var d := _drag
	_drag = Drag.IDLE
	_drag_note = null
	_bend_entry = {}
	match d:
		Drag.MARQUEE:
			if _marquee_live:
				_commit_marquee()
			elif not _selected.is_empty():
				_selected.clear()
				selection_changed.emit()
		Drag.CREATING:
			end_edit("Draw note")
		Drag.MOVING:
			end_edit("Move notes")
		Drag.RESIZING:
			end_edit("Resize notes")
		Drag.BEND_TIP:
			end_edit("Edit bend")
		Drag.BEND_START:
			end_edit("Move bend")
	queue_redraw()

# --- create / move / resize -------------------------------------------------

func _start_create(pos: Vector2) -> void:
	var beat := snap_beat(x_to_beat(pos.x))
	if beat < 0.0 or beat >= pattern.length_beats - 0.0001:
		return
	begin_edit()
	var n := PatternNote.new()
	n.beat = beat
	n.duration = snap_step
	var row := y_to_row(pos.y)
	n.index = clampi(row, INDEX_MIN, INDEX_MAX)
	n.velocity = 0.8
	pattern.notes.append(n)
	_selected = [n]
	_drag = Drag.CREATING
	_drag_note = n
	_recompute_range(true)
	selection_changed.emit()
	notify_live_edit()
	note_auditioned.emit(n)

func _start_move(n: PatternNote, pos: Vector2) -> void:
	if not _selected.has(n):
		_selected = [n]
		selection_changed.emit()
	begin_edit()
	_drag = Drag.MOVING
	_drag_note = n
	_drag_start = pos
	_drag_row_delta = 0
	_drag_origin = {}
	for s in _selected:
		_drag_origin[s] = {"beat": s.beat, "index": s.index}
	queue_redraw()

func _start_resize(n: PatternNote, pos: Vector2) -> void:
	if not _selected.has(n):
		_selected = [n]
		selection_changed.emit()
	begin_edit()
	_drag = Drag.RESIZING
	_drag_note = n
	_drag_start = pos
	_drag_origin = {}
	for s in _selected:
		_drag_origin[s] = {"duration": s.duration}
	queue_redraw()

func _drag_resize(pos: Vector2) -> void:
	var anchor: PatternNote = _drag_note
	var end_beat := maxf(snap_beat(x_to_beat(pos.x)), anchor.beat + snap_step)
	var delta := (end_beat - anchor.beat) - float(_drag_origin[anchor]["duration"])
	for s in _selected:
		if _drag_origin.has(s):
			s.duration = maxf(snap_step, float(_drag_origin[s]["duration"]) + delta)
	notify_live_edit()

func _drag_move(pos: Vector2) -> void:
	var anchor: PatternNote = _drag_note
	var ao: Dictionary = _drag_origin[anchor]
	var dx := pos.x - _drag_start.x
	var dy := pos.y - _drag_start.y
	var beat_delta := snap_beat(float(ao["beat"]) + dx / beat_width) - float(ao["beat"])
	var row_delta := int(roundf(-dy / row_height))
	var min_beat := INF
	var max_beat := -INF
	var min_idx := INT_MAX_
	var max_idx := -INT_MAX_
	for s in _drag_origin:
		min_beat = minf(min_beat, float(_drag_origin[s]["beat"]))
		max_beat = maxf(max_beat, float(_drag_origin[s]["beat"]))
		min_idx = mini(min_idx, int(_drag_origin[s]["index"]))
		max_idx = maxi(max_idx, int(_drag_origin[s]["index"]))
	beat_delta = clampf(beat_delta, -min_beat, maxf(-min_beat, pattern.length_beats - snap_step - max_beat))
	row_delta = clampi(row_delta, INDEX_MIN - min_idx, INDEX_MAX - max_idx)
	for s in _drag_origin:
		s.beat = float(_drag_origin[s]["beat"]) + beat_delta
		s.index = int(_drag_origin[s]["index"]) + row_delta
	if row_delta != _drag_row_delta:
		_drag_row_delta = row_delta
		_recompute_range(true)
		note_auditioned.emit(anchor)
	notify_live_edit()

const INT_MAX_ := 1 << 30

# --- bends -------------------------------------------------------------------

func _drag_bend_tip(pos: Vector2) -> void:
	var b: PatternBend = _bend_entry["bend"]
	var start_beat: float = _bend_entry["start_beat"]
	b.glide_beats = maxf(0.0, snap_beat(x_to_beat(pos.x)) - start_beat)
	var row := y_to_row(pos.y)
	b.index = clampi(row if track_type == MusicTrack.TrackType.DRUM else row - b.octave * rows_per_octave, INDEX_MIN, INDEX_MAX)
	_recompute_range(true)
	notify_live_edit()

func _drag_bend_start(pos: Vector2) -> void:
	var b: PatternBend = _bend_entry["bend"]
	var parent_start: float = _bend_entry["parent_start"]
	b.offset_beats = clampf(snap_beat(x_to_beat(pos.x)) - parent_start, 0.0, 256.0)
	notify_live_edit()

# --- marquee -----------------------------------------------------------------

func _commit_marquee() -> void:
	var rect := Rect2(_marquee_anchor, _mouse - _marquee_anchor).abs().intersection(_area)
	var picked: Array = []
	for n in pattern.notes:
		if note_rect(n).intersects(rect):
			picked.append(n)
	if _marquee_add:
		for n in picked:
			if not _selected.has(n):
				_selected.append(n)
	else:
		_selected = picked
	selection_changed.emit()

# ---------------------------------------------------------------------------
# Keys and clipboard
# ---------------------------------------------------------------------------

func _on_key(ev: InputEventKey) -> void:
	if not ev.pressed or pattern == null or read_only:
		return
	var cmd := ev.ctrl_pressed or ev.meta_pressed
	if cmd:
		match ev.keycode:
			KEY_C:
				copy_selection()
			KEY_X:
				copy_selection()
				delete_selection()
			KEY_V:
				paste()
			KEY_D:
				duplicate_selection()
			KEY_A:
				select_all()
			_:
				return
		accept_event()
		return
	match ev.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			delete_selection()
			accept_event()
		KEY_B:
			if not ev.alt_pressed:
				add_bend_at_mouse()
				accept_event()
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN:
			var dx := (1 if ev.keycode == KEY_RIGHT else -1) if ev.keycode in [KEY_LEFT, KEY_RIGHT] else 0
			var dy := (1 if ev.keycode == KEY_UP else -1) if ev.keycode in [KEY_UP, KEY_DOWN] else 0
			if nudge(dx, dy, ev.shift_pressed):
				accept_event()

## Move the selection: [param steps] snap steps in time, [param rows] rows in
## pitch ([param octave]: rows means octaves). With a bend selected, its offset
## and target move instead. False when there was nothing to move.
func nudge(steps: int, rows: int, octave: bool = false) -> bool:
	if pattern == null or read_only:
		return false
	if _sel_bend != null:
		var b := _sel_bend
		begin_edit()
		b.offset_beats = maxf(0.0, b.offset_beats + float(steps) * snap_step)
		b.index = clampi(b.index + rows * (rows_per_octave if octave and track_type != MusicTrack.TrackType.DRUM else (12 if octave else 1)), INDEX_MIN, INDEX_MAX)
		end_edit("Nudge bend")
		return true
	if _selected.is_empty():
		return false
	begin_edit()
	var latest := float(pattern.length_beats) - snap_step
	var pitched := false
	for n in _selected:
		if steps != 0:
			n.beat = clampf(n.beat + float(steps) * snap_step, 0.0, maxf(0.0, latest))
		if rows != 0:
			pitched = true
			if octave:
				if track_type == MusicTrack.TrackType.DRUM:
					n.index = clampi(n.index + 12 * rows, 0, INDEX_MAX)
				else:
					n.octave = clampi(n.octave + rows, -6, 6)
			else:
				n.index = clampi(n.index + rows, INDEX_MIN, INDEX_MAX)
	end_edit("Nudge notes")
	if pitched:
		note_auditioned.emit(_selected[0])
	return true

func delete_selection() -> void:
	if read_only:
		return
	if _sel_bend != null:
		remove_selected_bend()
		return
	if _selected.is_empty():
		return
	begin_edit()
	for n in _selected:
		pattern.notes.erase(n)
	_selected.clear()
	selection_changed.emit()
	end_edit("Delete notes")

func select_all() -> void:
	if pattern == null:
		return
	_clear_bend_selection()
	_selected = pattern.notes.duplicate()
	selection_changed.emit()
	queue_redraw()

func copy_selection() -> void:
	if _selected.is_empty():
		return
	_clipboard.clear()
	for n in _selected:
		_clipboard.append(_clone_note(n))

func has_clipboard() -> bool:
	return not _clipboard.is_empty()

func paste() -> void:
	if _clipboard.is_empty() or pattern == null or read_only:
		return
	var anchor := 0.0
	if _mouse_inside and _mouse.x >= _area.position.x:
		anchor = maxf(0.0, snap_beat(x_to_beat(_mouse.x)))
	var min_beat: float = _clipboard[0].beat
	for n in _clipboard:
		min_beat = minf(min_beat, n.beat)
	begin_edit()
	var made: Array = []
	for n in _clipboard:
		var c := _clone_note(n)
		c.beat = anchor + (n.beat - min_beat)
		pattern.notes.append(c)
		made.append(c)
	_clear_bend_selection()
	_selected = made
	selection_changed.emit()
	end_edit("Paste notes")

func duplicate_selection() -> void:
	if _selected.is_empty() or read_only:
		return
	begin_edit()
	var made: Array = []
	for n in _selected:
		var c := _clone_note(n)
		c.beat = n.beat + snap_step
		pattern.notes.append(c)
		made.append(c)
	_selected = made
	selection_changed.emit()
	end_edit("Duplicate notes")

static func _clone_note(n: PatternNote) -> PatternNote:
	var c := PatternNote.create(n.beat, n.duration, n.index, n.octave, n.accidental, n.velocity)
	for b in n.bends:
		c.bends.append(_clone_bend(b))
	return c

static func _clone_bend(b: PatternBend) -> PatternBend:
	var c := PatternBend.create(b.offset_beats, b.glide_beats, b.index, b.octave, b.accidental)
	for child in b.bends:
		c.bends.append(_clone_bend(child))
	return c
