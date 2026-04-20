class_name MusicTrack
extends Node

# Per-instrument voice in the dynamic music system. Reads a MusicPattern and
# resolves each PatternNote into a MIDI pitch based on the current MusicBlock's
# chord/scale (via MusicDirector), then drives a SynthEngine channel.
#
# Track types:
#   CHORD  — note.index = chord tone index (wraps with octave bump)
#   MELODY — note.index = scale degree (0-based, wraps); note.accidental = ± semitones
#   DRUM   — note.index = absolute MIDI note (no transposition)
#
# Pattern loops based on pattern.length_beats, independent of block duration.
# On block change, non-drum tracks release all sustaining notes so the new
# chord/scale takes effect cleanly.

enum TrackType { CHORD, MELODY, DRUM }

## How each PatternNote's [member PatternNote.index] is interpreted:
## [br]• CHORD — chord tone index (0 = root, 1 = third, 2 = fifth, ...).
## Wraps with an octave bump when index >= chord size.
## [br]• MELODY — 0-based scale degree (0 = tonic). Wraps similarly.
## PatternNote.accidental adds ± semitones for chromatic passing tones.
## [br]• DRUM — absolute MIDI note number. No chord/scale transposition.
@export var track_type: TrackType = TrackType.CHORD

## The looping pattern this track plays. Loops every [member MusicPattern.length_beats]
## regardless of block duration.
@export var pattern: MusicPattern

## Synth patch (timbre) used for this track's notes. Assigned to the
## target synth channel in [method _ready].
@export var patch: SynthPatch

## SynthEngine channel (0..15) this track owns. Two tracks sharing a
## channel will interfere — each note-off can kill the wrong note.
@export_range(0, 15) var synth_channel: int = 0

## Octave offset applied to all notes in this track. 4 = notes resolve
## around C4 (MIDI 60). Lower for bass, higher for lead melodies.
@export var base_octave: int = 4

# Runtime references — set by whoever spawns the track (autoload, demo, etc.).
var director: MusicDirector
var synth: SynthEngine

# --- Internal state ---------------------------------------------------------

# Each entry: {"midi": int, "off_time": float (in total_beats)}
var _active_notes: Array = []
var _prev_cursor: float = -0.001
var _was_playing: bool = false

func _ready() -> void:
	# Fallback wiring for code-created tracks where director/synth are
	# assigned before add_child(). Scene-child tracks use bind() instead
	# because _ready fires on children before their parent MusicPlayer.
	if director and synth:
		bind(director, synth)

## Assign the runtime MusicDirector + SynthEngine refs and complete wiring
## (signal connection, patch assignment). Called by MusicPlayer after scene
## instantiation, or can be called manually from code.
func bind(p_director: MusicDirector, p_synth: SynthEngine) -> void:
	director = p_director
	synth = p_synth
	if not director.block_changed.is_connected(_on_block_changed):
		director.block_changed.connect(_on_block_changed)
	if not director.seeked.is_connected(_on_seeked):
		director.seeked.connect(_on_seeked)
	if patch:
		synth.set_patch(synth_channel, patch)

func _on_seeked() -> void:
	# Release sustaining notes so they don't hang past the new position.
	_release_all()
	# Reset cursor tracking so the pattern doesn't think it wrapped.
	_prev_cursor = -0.001

func _process(_delta: float) -> void:
	if director == null or synth == null or pattern == null:
		return
	if pattern.notes.is_empty():
		return

	# Detect play/stop transitions.
	if not director.playing:
		if _was_playing:
			_release_all()
			_was_playing = false
		return
	if not _was_playing:
		_prev_cursor = -0.001
		_was_playing = true

	var total: float = director.get_total_beats()
	var length: float = pattern.length_beats
	if length <= 0.0:
		return
	var cursor: float = fposmod(total, length)
	var wrapped: bool = cursor < _prev_cursor - 0.001

	# --- Trigger notes whose swung beat falls in the traversed range ----
	for note in pattern.notes:
		var swung: float = fposmod(director.get_swung_beat(note.beat), length)
		var should_trigger: bool = false
		if wrapped:
			should_trigger = (swung > _prev_cursor and swung <= length) or swung <= cursor
		else:
			should_trigger = swung > _prev_cursor and swung <= cursor
		if should_trigger:
			_trigger_note(note, total)

	# --- Release notes whose duration has elapsed -----------------------
	var i: int = _active_notes.size() - 1
	while i >= 0:
		var entry: Dictionary = _active_notes[i]
		if total >= entry["off_time"]:
			synth.note_off(synth_channel, entry["midi"])
			_active_notes.remove_at(i)
		i -= 1

	_prev_cursor = cursor

# ---------------------------------------------------------------------------
# Note resolution
# ---------------------------------------------------------------------------

func _trigger_note(note: PatternNote, total_beats: float) -> void:
	var midi: int = _resolve_midi(note)
	synth.note_on(synth_channel, midi, note.velocity)
	# Duration is in beats; total_beats is the same timescale.
	var off_time: float = total_beats + note.duration
	_active_notes.append({"midi": midi, "off_time": off_time})

func _resolve_midi(note: PatternNote) -> int:
	match track_type:
		TrackType.CHORD:
			return _resolve_chord(note)
		TrackType.MELODY:
			return _resolve_melody(note)
		_: # DRUM
			return note.index

func _resolve_chord(note: PatternNote) -> int:
	var block := director.get_current_block()
	if block == null:
		return 60
	var intervals := block.chord_intervals
	var size: int = intervals.size()
	if size == 0:
		return 60
	var idx: int = posmod(note.index, size)
	var extra_oct: int = int(floorf(float(note.index) / float(size)))
	return 12 * (base_octave + 1 + note.octave + extra_oct) + block.chord_root + intervals[idx]

func _resolve_melody(note: PatternNote) -> int:
	var block := director.get_current_block()
	if block == null:
		return 60
	var intervals := block.scale_intervals
	var size: int = intervals.size()
	if size == 0:
		return 60
	var idx: int = posmod(note.index, size)
	var extra_oct: int = int(floorf(float(note.index) / float(size)))
	return 12 * (base_octave + 1 + note.octave + extra_oct) + block.scale_root + intervals[idx] + note.accidental

# ---------------------------------------------------------------------------
# Block change — release sustaining notes for pitched tracks
# ---------------------------------------------------------------------------

func _on_block_changed(_block: MusicBlock, _index: int) -> void:
	if track_type == TrackType.DRUM:
		return
	_release_all()

func _release_all() -> void:
	for entry in _active_notes:
		synth.note_off(synth_channel, entry["midi"])
	_active_notes.clear()
