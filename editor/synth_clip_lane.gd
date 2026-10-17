@tool
class_name SynthClipLane
extends Control

# The right-hand half of a track lane: the track's pattern drawn as a clip that
# repeats at the pattern's length across the timeline, each clip with a small
# picture of its notes (one tick per note, higher pitch higher up). Block
# boundaries run behind it. The picture is cached; nothing here redraws while the
# song plays (the playhead is a layer of its own).
#
# A PatternChain is drawn as its steps instead: one clip per step and per repeat
# of the step, the chain as a whole repeating across the timeline. The first play
# of a step carries its name and badges; its repeats and the later trips through
# the chain are dimmed, like the progression lane's repeats.

signal pressed
signal clip_activated
## A step's clip was pressed / double-clicked (index into the chain's steps).
signal step_pressed(step: int)
signal step_activated(step: int)
## With a song: a region of the lane was pressed; [param entry] is its song entry.
signal region_pressed(entry: int)
## With a song: a region was double-clicked; [param pattern] is the one it plays or
## carries on with (null if it plays none).
signal region_activated(pattern: MusicPattern)

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
## The chain step drawn selected (-1 none).
var selected_step: int = -1:
	set(v):
		selected_step = v
		queue_redraw()

## With a song: SynthSongLayout.lane_regions() of the track, each with a "tint" (the
## section's colour) added. Empty: the lane draws its one pattern as before.
var regions: Array = []:
	set(v):
		regions = v
		queue_redraw()
## The entry drawn selected in a song (-1 none).
var selected_entry: int = -1:
	set(v):
		selected_entry = v
		queue_redraw()

# [beat, duration, 0..1 height (1 = highest)]
var _ticks: Array = []
# A pattern -> its note picture and clips, for the patterns the regions play.
var _pics: Dictionary = {}
# A chain's clips, in play order: {step, repeat, beat, length, label, tip, ticks}.
var _segs: Array = []

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
	var pic := _picture(pattern)
	_ticks = pic["ticks"]
	_segs = pic["segs"]
	_pics.clear()
	for r in regions:
		if r["pattern"] != null and not _pics.has(r["pattern"]):
			_pics[r["pattern"]] = _picture(r["pattern"])
	queue_redraw()

# The note picture of [param p] (one tick per note) and, for a chain, its clips.
func _picture(p: MusicPattern) -> Dictionary:
	var ticks: Array = []
	var play_notes: Array[PatternNote] = []
	if p != null:
		play_notes = p.get_play_notes()
	if not play_notes.is_empty():
		var block: MusicBlock = timeline.data.blocks[0] if timeline != null and timeline.data != null and not timeline.data.blocks.is_empty() else null
		var rpo := SynthPitchMap.rows_per_octave(track_type, block)
		var lo := 1 << 30
		var hi := -(1 << 30)
		var rows: Array = []
		for n in play_notes:
			var r := SynthPitchMap.display_row(track_type, n.index, n.octave, rpo)
			rows.append(r)
			lo = mini(lo, r)
			hi = maxi(hi, r)
		for i in play_notes.size():
			var n: PatternNote = play_notes[i]
			var h := 0.5 if hi == lo else float(rows[i] - lo) / float(hi - lo)
			ticks.append([n.beat, n.duration, h])
	var segs: Array = []
	if p is PatternChain:
		segs = _build_segments(p as PatternChain, ticks)
	return {"ticks": ticks, "segs": segs}

# The chain's clips, and each one's share of the note picture [param ticks] (the
# flattened ticks already hold every repeat, transposed and scaled).
func _build_segments(chain: PatternChain, ticks: Array) -> Array:
	var segs: Array = []
	for e in chain.get_step_layout():
		var step: PatternChainStep = chain.steps[e["step"]]
		var pname := SynthSongContext.pattern_name(step.pattern)
		var badges := step_badges(step)
		segs.append({"step": e["step"], "repeat": e["repeat"], "beat": e["beat"], "length": e["length"],
				"label": pname if badges == "" else "%s  %s" % [pname, badges],
				"tip": "Step %d: %s%s\n%s beats, repeat %d of %d." % [e["step"] + 1, pname,
						"" if badges == "" else " (%s)" % badges, e["length"], e["repeat"] + 1, step.repeats],
				"ticks": []})
	for t in ticks:
		for i in range(segs.size() - 1, -1, -1):
			if segs[i]["beat"] <= t[0] + 0.00001:
				segs[i]["ticks"].append(t)
				break
	return segs

## The badges a step's clip shows: "+1 oct" when transposed, "×0.8" when scaled.
static func step_badges(step: PatternChainStep) -> String:
	var out := PackedStringArray()
	if step.octave_shift != 0:
		out.append("%+d oct" % step.octave_shift)
	if not is_equal_approx(step.velocity_scale, 1.0):
		out.append("×%s" % String.num(step.velocity_scale, 2))
	return " ".join(out)

## How many clips a chain draws per trip through it (0 for a plain pattern).
func segment_count() -> int:
	return _segs.size()

## The step and repeat of chain clip [param seg].
func segment_info(seg: int) -> Dictionary:
	return {"step": _segs[seg]["step"], "repeat": _segs[seg]["repeat"], "label": _segs[seg]["label"]}

## The chain clip that is repeat [param repeat] of step [param step], or -1.
func find_segment(step: int, repeat: int = 0) -> int:
	for i in _segs.size():
		if _segs[i]["step"] == step and _segs[i]["repeat"] == repeat:
			return i
	return -1

## Rect of chain clip [param seg] in trip [param trip] through the chain.
func segment_rect(seg: int, trip: int = 0) -> Rect2:
	if seg < 0 or seg >= _segs.size() or timeline == null:
		return Rect2()
	var s := SynthRackStyle.scale(self)
	var start: float = float(trip) * pattern.get_play_length() + _segs[seg]["beat"]
	var x0 := timeline.x_of(start, size.x)
	var x1 := timeline.x_of(minf(start + _segs[seg]["length"], timeline.span), size.x)
	return Rect2(x0 + 1.0, 4.0 * s, maxf(2.0, x1 - x0 - 2.0), maxf(1.0, size.y - 8.0 * s))

# [clip, trip] under [param pos], or [-1, -1].
func _segment_at(pos: Vector2) -> Array:
	if _segs.is_empty() or timeline == null or pattern.get_play_length() <= 0.0:
		return [-1, -1]
	var trip := int(floorf(timeline.beat_of(pos.x, size.x) / pattern.get_play_length()))
	for i in _segs.size():
		if segment_rect(i, trip).has_point(pos):
			return [i, trip]
	return [-1, -1]

## Rect of the first clip, for tests and hit-testing.
func clip_rect(repeat: int = 0) -> Rect2:
	var s := SynthRackStyle.scale(self)
	if pattern == null or pattern.get_play_length() <= 0.0 or timeline == null:
		return Rect2()
	var start := float(repeat) * pattern.get_play_length()
	var x0 := timeline.x_of(start, size.x)
	var x1 := timeline.x_of(minf(start + pattern.get_play_length(), timeline.span), size.x)
	return Rect2(x0 + 1.0, 4.0 * s, maxf(2.0, x1 - x0 - 2.0), size.y - 8.0 * s)

func _clip_at(pos: Vector2) -> bool:
	if pattern == null or pattern.get_play_length() <= 0.0 or timeline == null:
		return false
	var reps := int(ceilf(timeline.span / pattern.get_play_length() - 0.0001))
	var rep := int(floorf(timeline.beat_of(pos.x, size.x) / pattern.get_play_length()))
	return rep >= 0 and rep < reps and clip_rect(rep).has_point(pos)

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit()
		if timeline != null and timeline.song != null:
			var ri := region_at(mb.position)
			if ri >= 0:
				region_pressed.emit(regions[ri]["entry"])
				if mb.double_click:
					region_activated.emit(regions[ri]["pattern"])
		elif pattern is PatternChain:
			var hit := _segment_at(mb.position)
			if hit[0] >= 0:
				var step: int = _segs[hit[0]]["step"]
				step_pressed.emit(step)
				if mb.double_click:
					step_activated.emit(step)
		elif mb.double_click and _clip_at(mb.position):
			clip_activated.emit()
		accept_event()

func _get_tooltip(at_position: Vector2) -> String:
	if timeline != null and timeline.song != null:
		return _region_tip(region_at(at_position))
	if pattern == null:
		return "This track has no pattern."
	if pattern is PatternChain:
		var hit := _segment_at(at_position)
		if hit[0] < 0:
			return ""
		return "%s\nChain %s: %s beats, %d notes, repeating.\nClick to select the step, double-click to edit its pattern in Pattern." % [
				_segs[hit[0]]["tip"], clip_name, pattern.get_play_length(), pattern.get_play_notes().size()]
	if _clip_at(at_position):
		return "%s: %s beats, %d notes, repeating.\nDouble-click to edit it in Pattern." % [clip_name, pattern.get_play_length(), pattern.get_play_notes().size()]
	return ""

## The index in [member regions] of the region at [param pos], or -1.
func region_at(pos: Vector2) -> int:
	if timeline == null:
		return -1
	for i in regions.size():
		if pos.x >= timeline.x_of(regions[i]["start"], size.x) and pos.x < timeline.x_of(regions[i]["end"], size.x):
			return i
	return -1

## Rect of region [param i], whole height.
func region_rect(i: int) -> Rect2:
	var x0 := timeline.x_of(regions[i]["start"], size.x)
	return Rect2(x0, 0.0, timeline.x_of(regions[i]["end"], size.x) - x0, size.y)

func _region_tip(i: int) -> String:
	if i < 0:
		return ""
	var rg: Dictionary = regions[i]
	var where := "%s (entry %d)" % [SynthSongLayout.section_label(rg["section"]), int(rg["entry"]) + 1]
	var pname := SynthSongContext.pattern_name(rg["pattern"]) if rg["pattern"] != null else "none"
	match int(rg["kind"]):
		SynthSongLayout.Kind.PLAY:
			return "%s: plays %s from the section start.\nDouble-click to edit it in Pattern." % [where, pname]
		SynthSongLayout.Kind.SILENT:
			return "%s: this track is silent." % where
	match int(rg["carry"]):
		SynthSongLayout.Carry.NONE:
			return "%s: keep. The track is not playing, and nothing starts it yet." % where
		SynthSongLayout.Carry.SILENT:
			return "%s: keep. The track stays silent." % where
	return "%s: keep. The track carries on with %s, without restarting.\nDouble-click to edit it in Pattern." % [where, pname]

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
	if timeline.song != null:
		_draw_regions(s, ppb, font, fs)
	elif pattern == null or pattern.get_play_length() <= 0.0:
		draw_string(font, Vector2(8.0 * s, size.y * 0.5 + 4.0 * s), "no pattern" if pattern == null else "empty chain",
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0 * s, fs, SynthRackStyle.dim(self))
	elif pattern is PatternChain:
		_draw_chain(s, ppb, font, fs)
	else:
		var alpha := 1.0 if audible else 0.35
		var reps := int(ceilf(timeline.span / pattern.get_play_length() - 0.0001))
		for rep in reps:
			var r := clip_rect(rep)
			draw_rect(r, Color(color, 0.22 * alpha))
			draw_rect(r, Color(color, 0.85 * alpha), false, 1.0)
			var inner := r.grow(-3.0 * s)
			var nh := clampf(inner.size.y / 12.0, 2.0, 4.0 * s)
			var start := float(rep) * pattern.get_play_length()
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

func _draw_chain(s: float, ppb: float, font: Font, fs: int) -> void:
	var alpha := 1.0 if audible else 0.35
	var length := pattern.get_play_length()
	var trips := int(ceilf(timeline.span / length - 0.0001))
	var accent := SynthRackStyle.accent(self)
	for trip in trips:
		for i in _segs.size():
			var seg: Dictionary = _segs[i]
			var r := segment_rect(i, trip)
			if r.position.x >= size.x:
				continue
			# Dim what is a repeat: of a step, or of the whole chain.
			var a := alpha * (1.0 if trip == 0 else 0.5) * (1.0 if seg["repeat"] == 0 else 0.6)
			var c := color if int(seg["step"]) % 2 == 0 else color.lightened(0.22)
			draw_rect(r, Color(c, 0.22 * a))
			draw_rect(r, Color(c, 0.85 * a), false, 1.0)
			var inner := r.grow(-3.0 * s)
			var nh := clampf(inner.size.y / 12.0, 2.0, 4.0 * s)
			var start := float(trip) * length
			for t in seg["ticks"]:
				var bx: float = timeline.x_of(start + t[0], size.x)
				if bx >= r.end.x - 0.5:
					continue
				var w := minf(maxf(1.0, t[1] * ppb), r.end.x - bx - 1.0)
				var y: float = inner.position.y + (1.0 - t[2]) * (inner.size.y - nh)
				draw_rect(Rect2(bx, y, maxf(1.0, w), nh), Color(c.lightened(0.25), 0.95 * a))
			if int(seg["step"]) == selected_step:
				draw_rect(r, accent if trip == 0 else Color(accent, 0.5), false, 2.0 * s)
			if seg["repeat"] == 0 and r.size.x > 34.0 * s:
				draw_string(font, Vector2(r.position.x + 4.0 * s, r.position.y + fs + 1.0 * s), seg["label"],
						HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8.0 * s, fs, Color(1, 1, 1, 0.8 * a))

# ---------------------------------------------------------------------------
# A song's regions
# ---------------------------------------------------------------------------

func _draw_regions(s: float, ppb: float, font: Font, fs: int) -> void:
	var dim := SynthRackStyle.dim(self)
	var base_alpha := 1.0 if audible else 0.35
	for i in regions.size():
		var rg: Dictionary = regions[i]
		var r := region_rect(i)
		var tint: Color = rg.get("tint", color)
		draw_rect(r, Color(tint, 0.10))
		draw_rect(Rect2(r.position.x, 0.0, r.size.x, 2.0 * s), Color(tint, 0.9))
		var inner := Rect2(r.position.x + 1.0, 4.0 * s, maxf(1.0, r.size.x - 2.0), maxf(1.0, size.y - 8.0 * s))
		var label_x := r.position.x + 4.0 * s
		var wide := r.size.x > 44.0 * s
		var text := ""
		match int(rg["kind"]):
			SynthSongLayout.Kind.PLAY:
				if rg["pattern"] == null or rg["pattern"].get_play_length() <= 0.0:
					text = "no pattern"
				else:
					_draw_run(rg, inner, color, base_alpha, ppb, s, font, fs, true)
			SynthSongLayout.Kind.SILENT:
				_hatch(inner, Color(dim, 0.5 * base_alpha), 7.0 * s)
				text = "silent"
			_:
				match int(rg["carry"]):
					SynthSongLayout.Carry.NONE:
						text = "off"
					SynthSongLayout.Carry.SILENT:
						_hatch(inner, Color(dim, 0.25 * base_alpha), 9.0 * s)
						text = "keep: silent"
					_:
						if rg["pattern"] == null or rg["pattern"].get_play_length() <= 0.0:
							text = "keep: no pattern"
						else:
							_draw_run(rg, inner, color, base_alpha * 0.45, ppb, s, font, fs, false)
		if text != "" and wide:
			draw_string(font, Vector2(label_x, size.y * 0.5 + fs * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT,
					maxf(0.0, r.size.x - 8.0 * s), fs, Color(dim, dim.a * base_alpha))
		# The section boundary.
		draw_line(Vector2(r.position.x, 0), Vector2(r.position.x, size.y), Color(SynthRackStyle.grid(self), 0.5), 1.0)
		if int(rg["entry"]) == selected_entry:
			draw_rect(Rect2(r.position.x, 0.0, r.size.x, size.y), Color(SynthRackStyle.accent(self), 0.12))

# The pattern of region [param rg] repeating from its origin, clipped to [param inner].
# [param labelled]: the first clip of each chain step carries its name (a PLAY region),
# else "keep" over the first clip.
func _draw_run(rg: Dictionary, inner: Rect2, col: Color, alpha: float, ppb: float, s: float, font: Font, fs: int, labelled: bool) -> void:
	var p: MusicPattern = rg["pattern"]
	var pic: Dictionary = _pics.get(p, {})
	if pic.is_empty():
		return
	var length := p.get_play_length()
	var origin: float = rg["origin"]
	var rstart: float = rg["start"]
	var rend: float = rg["end"]
	var segs: Array = pic["segs"]
	var plain := segs.is_empty()
	if plain:
		segs = [{"step": 0, "repeat": 0, "beat": 0.0, "length": length, "label": SynthSongContext.pattern_name(p), "ticks": pic["ticks"]}]
	var trip := int(floorf((rstart - origin) / length))
	var labelled_keep := false
	while origin + float(trip) * length < rend - 0.0001:
		var tstart := origin + float(trip) * length
		for seg in segs:
			var a: float = tstart + seg["beat"]
			var b: float = a + seg["length"]
			if b <= rstart + 0.0001 or a >= rend - 0.0001:
				continue
			var x0 := maxf(timeline.x_of(a, size.x), inner.position.x)
			var x1 := minf(timeline.x_of(b, size.x), inner.end.x)
			if x1 <= x0:
				continue
			var c := col if int(seg["step"]) % 2 == 0 else col.lightened(0.22)
			var a2 := alpha * (1.0 if seg["repeat"] == 0 else 0.6)
			var cr := Rect2(x0, inner.position.y, x1 - x0, inner.size.y)
			draw_rect(cr, Color(c, 0.22 * a2))
			draw_rect(cr, Color(c, 0.85 * a2), false, 1.0)
			var tin := cr.grow(-3.0 * s)
			var nh := clampf(tin.size.y / 12.0, 2.0, 4.0 * s)
			for t in seg["ticks"]:
				var nb: float = tstart + t[0]
				if nb < rstart - 0.0001 or nb >= rend - 0.0001:
					continue
				var bx := maxf(timeline.x_of(nb, size.x), cr.position.x)    # a note on the first beat sits in the clip's inset
				if bx >= cr.end.x - 0.5:
					continue
				var w := minf(maxf(1.0, t[1] * ppb), cr.end.x - bx - 1.0)
				var y: float = tin.position.y + (1.0 - t[2]) * (tin.size.y - nh)
				draw_rect(Rect2(bx, y, maxf(1.0, w), nh), Color(c.lightened(0.25), 0.95 * a2))
			if labelled and seg["repeat"] == 0 and cr.size.x > 34.0 * s and (not plain or a >= rstart - 0.0001):
				draw_string(font, Vector2(cr.position.x + 4.0 * s, cr.position.y + fs + 1.0 * s), seg["label"],
						HORIZONTAL_ALIGNMENT_LEFT, cr.size.x - 8.0 * s, fs, Color(1, 1, 1, 0.8 * alpha))
			elif not labelled and not labelled_keep and cr.size.x > 34.0 * s:
				labelled_keep = true
				draw_string(font, Vector2(cr.position.x + 4.0 * s, cr.position.y + fs + 1.0 * s), "keep",
						HORIZONTAL_ALIGNMENT_LEFT, cr.size.x - 8.0 * s, fs, Color(1, 1, 1, 0.9))
		trip += 1

# Diagonal lines across [param r], clipped to it.
func _hatch(r: Rect2, col: Color, step: float) -> void:
	var h := r.size.y
	var d := r.position.x - h
	while d < r.end.x:
		var t0 := maxf(0.0, (r.position.x - d) / h)
		var t1 := minf(1.0, (r.end.x - d) / h)
		if t1 > t0:
			draw_line(Vector2(d + t0 * h, r.end.y - t0 * h), Vector2(d + t1 * h, r.end.y - t1 * h), col, 1.0)
		d += step
