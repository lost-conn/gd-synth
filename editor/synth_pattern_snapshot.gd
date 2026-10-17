@tool
class_name SynthPatternSnapshot
extends RefCounted

# Everything the Pattern view can edit in a MusicPattern, captured so that one
# gesture is one undo action: the view records a snapshot before a gesture and
# one after, and Undo / Redo apply them. Notes and bends are kept as the very
# same Resource objects (their fields are restored, never re-created), so a
# selection, an open Godot inspector and the playing MusicTrack all survive an
# undo.
#
# An instance is handed to EditorUndoRedoManager as the object of a do / undo
# method (apply), and as a reference so it outlives the view that made it.

var pattern: MusicPattern
var data: Dictionary = {}

static func capture(p: MusicPattern) -> SynthPatternSnapshot:
	var s := SynthPatternSnapshot.new()
	s.pattern = p
	s.data = _capture_data(p, true)
	return s

## A plain-values string of the pattern, for "has it changed since it was saved".
static func fingerprint(p: MusicPattern) -> String:
	return var_to_str(_capture_data(p, false))

static func _capture_data(p: MusicPattern, with_refs: bool) -> Dictionary:
	# A PatternChain's notes and length are derived from its steps: only its
	# editor hint is the view's to edit.
	if p is PatternChain:
		return {"length": 0.0, "type": int(p.editor_track_type), "notes": []}
	var notes: Array = []
	for n in p.notes:
		var e := {
			"beat": n.beat, "duration": n.duration, "index": n.index, "octave": n.octave,
			"accidental": n.accidental, "velocity": n.velocity, "bends": _capture_bends(n.bends, with_refs),
		}
		if with_refs:
			e["ref"] = n
		notes.append(e)
	return {"length": p.length_beats, "type": int(p.editor_track_type), "notes": notes}

static func _capture_bends(bends: Array, with_refs: bool) -> Array:
	var out: Array = []
	for b in bends:
		var e := {
			"offset": b.offset_beats, "glide": b.glide_beats, "index": b.index, "octave": b.octave,
			"accidental": b.accidental, "bends": _capture_bends(b.bends, with_refs),
		}
		if with_refs:
			e["ref"] = b
		out.append(e)
	return out

## True when [param other] holds the same values (same notes, same fields).
func same_as(other: SynthPatternSnapshot) -> bool:
	return other != null and data == other.data

## Put the pattern back as captured. Emits the pattern's `changed`, which is how
## every view of it (roll, lane, inspector, Godot's own inspector) refreshes.
func apply() -> void:
	if pattern == null:
		return
	if pattern is PatternChain:
		pattern.editor_track_type = data["type"]
		pattern.emit_changed()
		return
	pattern.length_beats = data["length"]
	pattern.editor_track_type = data["type"]
	pattern.notes.clear()
	for e in data["notes"]:
		var n: PatternNote = e["ref"]
		n.beat = e["beat"]
		n.duration = e["duration"]
		n.index = e["index"]
		n.octave = e["octave"]
		n.accidental = e["accidental"]
		n.velocity = e["velocity"]
		n.bends.clear()
		_restore_bends(n.bends, e["bends"])
		pattern.notes.append(n)
	pattern.emit_changed()

static func _restore_bends(into: Array, list: Array) -> void:
	for e in list:
		var b: PatternBend = e["ref"]
		b.offset_beats = e["offset"]
		b.glide_beats = e["glide"]
		b.index = e["index"]
		b.octave = e["octave"]
		b.accidental = e["accidental"]
		b.bends.clear()
		_restore_bends(b.bends, e["bends"])
		into.append(b)
