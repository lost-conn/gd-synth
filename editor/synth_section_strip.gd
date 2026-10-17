@tool
class_name SynthSectionStrip
extends Control

# The song's running order across the top of the Track view: one chip per repeat of
# every entry, as wide as the section is long, named after the section, on the
# timeline the lanes below share. A section keeps its colour wherever it appears.
# The loop entry carries a loop marker, and an arrow at the end of the song comes
# back to it. A click selects the chip's entry (the view edits its section below).

signal entry_selected(entry: int)

var timeline: SynthTimeline
## The selected entry (-1 none): its chips are outlined, and the other entries that
## play the same section are marked lightly.
var selected_entry: int = -1:
	set(v):
		selected_entry = v
		queue_redraw()

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true

func _ready() -> void:
	custom_minimum_size.y = 34.0 * SynthRackStyle.scale(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

## Rect of the chip for repeat [param repeat] of entry [param entry], or an empty Rect2.
func chip_rect(entry: int, repeat: int = 0) -> Rect2:
	for c in chips():
		if c["entry"] == entry and c["repeat"] == repeat:
			return c["rect"]
	return Rect2()

## Every chip: {entry, repeat, rect, section, color, label, loop (this chip starts
## the loop region)}.
func chips() -> Array:
	var out: Array = []
	if timeline == null or timeline.song == null:
		return out
	var s := SynthRackStyle.scale(self)
	var song := timeline.song
	var loop_entry := song.get_loop_entry()
	for seg in timeline.segments:
		var x0 := timeline.x_of(seg["start"], size.x)
		var x1 := timeline.x_of(minf(seg["start"] + seg["length"], timeline.span), size.x)
		var section: MusicSection = seg["section"]
		var label := SynthSongLayout.section_label(section)
		if section.repeats > 1:
			label += " ×%d" % section.repeats
		if song.entries[seg["entry"]].repeats > 1:
			label += "  %d/%d" % [int(seg["repeat"]) + 1, song.entries[seg["entry"]].repeats]
		out.append({"entry": seg["entry"], "repeat": seg["repeat"], "section": section,
				"rect": Rect2(x0 + 1.0, 3.0 * s, maxf(2.0, x1 - x0 - 2.0), size.y - 6.0 * s),
				"color": SynthSongLayout.section_color(song, section), "label": label,
				"loop": seg["entry"] == loop_entry and seg["repeat"] == 0})
	return out

func _chip_at(pos: Vector2) -> Dictionary:
	for c in chips():
		if (c["rect"] as Rect2).has_point(pos):
			return c
	return {}

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		var c := _chip_at(mb.position)
		if not c.is_empty():
			selected_entry = c["entry"]
			entry_selected.emit(c["entry"])
			accept_event()

func _get_tooltip(at_position: Vector2) -> String:
	var c := _chip_at(at_position)
	if c.is_empty() or timeline == null or timeline.song == null:
		return ""
	var song := timeline.song
	var e: MusicSongEntry = song.entries[c["entry"]]
	var length := song.section_length(c["section"])
	var tip := "Entry %d: %s, %s beats%s.\nClick to edit the section." % [int(c["entry"]) + 1, SynthSongLayout.section_label(c["section"]),
			String.num(length, 2), "" if e.repeats <= 1 else ", repeat %d of %d" % [int(c["repeat"]) + 1, e.repeats]]
	if c["loop"]:
		tip += "\nThe song loops back to here after its last entry."
	return tip

func _draw() -> void:
	var s := SynthRackStyle.scale(self)
	draw_rect(Rect2(Vector2.ZERO, size), SynthRackStyle.inset(self))
	if timeline == null or timeline.song == null or timeline.segments.is_empty():
		draw_string(SynthRackStyle.font(self), Vector2(8.0 * s, size.y * 0.5 + 5.0 * s),
				"The song has no section with a length.", HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0 * s,
				SynthRackStyle.font_size(self), SynthRackStyle.dim(self))
		return
	var font := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.95)
	var accent := SynthRackStyle.accent(self)
	var marker := SynthRackStyle.marker(self)
	var song := timeline.song
	var sel_section: MusicSection = song.entries[selected_entry].section \
			if selected_entry >= 0 and selected_entry < song.entries.size() and song.entries[selected_entry] != null else null
	for c in chips():
		var r: Rect2 = c["rect"]
		var col: Color = c["color"]
		var later: bool = c["repeat"] > 0
		col.a = 0.55 if later else 0.95
		draw_rect(r, col)
		if c["entry"] == selected_entry:
			draw_rect(r, accent, false, 2.0 * s)
		elif sel_section != null and c["section"] == sel_section:
			draw_rect(r.grow(-1.0), Color(1, 1, 1, 0.45), false, 1.0)
		if c["loop"]:
			var x := r.position.x - 1.0
			draw_line(Vector2(x, 0), Vector2(x, size.y), marker, 2.0 * s)
			draw_colored_polygon(PackedVector2Array([Vector2(x, 0), Vector2(x + 9.0 * s, 0), Vector2(x, 9.0 * s)]), marker)
		if r.size.x < 14.0 * s:
			continue
		var tx := r.position.x + (10.0 * s if c["loop"] else 5.0 * s)
		draw_string(font, Vector2(tx, r.position.y + r.size.y * 0.5 + fs * 0.35), c["label"],
				HORIZONTAL_ALIGNMENT_LEFT, maxf(0.0, r.end.x - tx - 3.0 * s), fs, Color(1, 1, 1, 0.55 if later else 1.0))
	# The way back: from the end of the last chip a hook returns to the loop entry's
	# marker, drawn along the bottom edge.
	var loop_x := timeline.x_of(song.get_loop_start_beats(), size.x)
	var end_x := timeline.x_of(song.get_length_beats(), size.x)
	var y := size.y - 2.0 * s
	draw_line(Vector2(loop_x + 2.0, y), Vector2(end_x - 2.0, y), Color(marker, 0.8), 1.5 * s)
	draw_colored_polygon(PackedVector2Array([Vector2(loop_x + 2.0, y), Vector2(loop_x + 2.0 + 6.0 * s, y - 3.0 * s),
			Vector2(loop_x + 2.0 + 6.0 * s, y + 3.0 * s)]), marker)
