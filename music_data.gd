class_name MusicData
extends Resource

# Data model for the dynamic music system. All inner classes extend
# RefCounted and are constructed in code via static create() factories.
#
# A MusicData holds a BPM and an array of MusicBlocks (the chord
# progression). Each block defines a chord (root + intervals) and a
# scale (root + intervals) that tracks read from to resolve pattern
# notes into MIDI pitches.

# --- Note name helpers (semitone offsets from C) ----------------------------

const C  := 0
const Cs := 1
const Db := 1
const D  := 2
const Ds := 3
const Eb := 3
const E  := 4
const F  := 5
const Fs := 6
const Gb := 6
const G  := 7
const Gs := 8
const Ab := 8
const A  := 9
const As := 10
const Bb := 10
const B  := 11

# --- Scale interval presets -------------------------------------------------
# static var because PackedInt32Array() is not a const expression in GDScript.

static var MAJOR: PackedInt32Array         = PackedInt32Array([0, 2, 4, 5, 7, 9, 11])
static var MINOR: PackedInt32Array         = PackedInt32Array([0, 2, 3, 5, 7, 8, 10])
static var DORIAN: PackedInt32Array        = PackedInt32Array([0, 2, 3, 5, 7, 9, 10])
static var PHRYGIAN: PackedInt32Array      = PackedInt32Array([0, 1, 3, 5, 7, 8, 10])
static var LYDIAN: PackedInt32Array        = PackedInt32Array([0, 2, 4, 6, 7, 9, 11])
static var MIXOLYDIAN: PackedInt32Array    = PackedInt32Array([0, 2, 4, 5, 7, 9, 10])
static var AEOLIAN: PackedInt32Array       = PackedInt32Array([0, 2, 3, 5, 7, 8, 10])
static var PENTA_MAJOR: PackedInt32Array   = PackedInt32Array([0, 2, 4, 7, 9])
static var PENTA_MINOR: PackedInt32Array   = PackedInt32Array([0, 3, 5, 7, 10])
static var BLUES: PackedInt32Array         = PackedInt32Array([0, 3, 5, 6, 7, 10])
static var CHROMATIC: PackedInt32Array     = PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])

# --- Chord interval presets -------------------------------------------------

static var CHORD_MAJ: PackedInt32Array  = PackedInt32Array([0, 4, 7])
static var CHORD_MIN: PackedInt32Array  = PackedInt32Array([0, 3, 7])
static var CHORD_DIM: PackedInt32Array  = PackedInt32Array([0, 3, 6])
static var CHORD_AUG: PackedInt32Array  = PackedInt32Array([0, 4, 8])
static var CHORD_MAJ7: PackedInt32Array = PackedInt32Array([0, 4, 7, 11])
static var CHORD_MIN7: PackedInt32Array = PackedInt32Array([0, 3, 7, 10])
static var CHORD_DOM7: PackedInt32Array = PackedInt32Array([0, 4, 7, 10])
static var CHORD_SUS2: PackedInt32Array = PackedInt32Array([0, 2, 7])
static var CHORD_SUS4: PackedInt32Array = PackedInt32Array([0, 5, 7])

# --- Inner classes ----------------------------------------------------------

class PatternNote extends RefCounted:
	var beat: float = 0.0       # position within pattern (in beats)
	var duration: float = 1.0   # note length in beats
	var index: int = 0          # chord tone (CHORD), scale degree (MELODY), MIDI note (DRUM)
	var octave: int = 0         # octave offset from track base_octave
	var accidental: int = 0     # semitones ± from scale degree (melody only)
	var velocity: float = 0.8

	static func create(p_beat: float, p_dur: float, p_index: int, p_oct: int = 0, p_acc: int = 0, p_vel: float = 0.8) -> PatternNote:
		var n := PatternNote.new()
		n.beat = p_beat
		n.duration = p_dur
		n.index = p_index
		n.octave = p_oct
		n.accidental = p_acc
		n.velocity = p_vel
		return n


class MusicBlock extends RefCounted:
	var chord_root: int = 0                                                     # 0-11
	var chord_intervals: PackedInt32Array = PackedInt32Array([0, 4, 7])          # triad
	var scale_root: int = 0                                                     # 0-11
	var scale_intervals: PackedInt32Array = PackedInt32Array([0, 2, 4, 5, 7, 9, 11])
	var duration_beats: int = 4

	static func create(
		p_chord_root: int,
		p_chord: PackedInt32Array,
		p_scale_root: int,
		p_scale: PackedInt32Array,
		p_beats: int = 4
	) -> MusicBlock:
		var b := MusicBlock.new()
		b.chord_root = p_chord_root
		b.chord_intervals = p_chord
		b.scale_root = p_scale_root
		b.scale_intervals = p_scale
		b.duration_beats = p_beats
		return b


class MusicPattern extends RefCounted:
	var notes: Array = []       # Array of PatternNote
	var length_beats: float = 4.0

	## Chainable helper for building patterns in code.
	func add(p_beat: float, p_dur: float, p_index: int, p_oct: int = 0, p_acc: int = 0, p_vel: float = 0.8) -> MusicPattern:
		notes.append(PatternNote.create(p_beat, p_dur, p_index, p_oct, p_acc, p_vel))
		return self


# --- MusicData fields -------------------------------------------------------

@export var bpm: float = 120.0
var blocks: Array = []  # Array of MusicBlock
