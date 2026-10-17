@tool
class_name MusicPattern
extends Resource

# A looping sequence of PatternNotes used by a MusicTrack. Loops
# independently of MusicBlock duration — the pattern cycles every
# length_beats regardless of which chord/scale is currently active.

## How many beats before the pattern loops. Independent of block duration —
## a 2-beat pattern plays twice per 4-beat block; an 8-beat pattern plays
## across two blocks. The pattern never resets on block boundaries.
@export var length_beats: float = 4.0

## The notes in this pattern. Order doesn't matter — notes fire when their
## [member PatternNote.beat] position is reached within the loop.
@export var notes: Array[PatternNote] = []

enum EditorTrackType { AUTO = -1, CHORD = 0, MELODY = 1, DRUM = 2 }

## Editor hint, not read at runtime: which kind of track this pattern is meant
## for, so the Synth tab's Pattern view can label its rows (chord tones, scale
## degrees, drum names) without guessing. [member MusicTrack.track_type] stays
## the authority when the game plays the pattern. AUTO (the default, never
## written to the file) lets the editor work it out from the MusicTrack that
## uses the pattern, or from the notes.
@export var editor_track_type: EditorTrackType = EditorTrackType.AUTO

## What this pattern plays, in the order and with the beats it is read at. The
## base returns [member notes]; a [PatternChain] returns its steps' notes
## flattened. Read the notes the pattern plays through this, not [member notes]
## (a chain has none of its own). Do not modify the result.
func get_play_notes() -> Array[PatternNote]:
	return notes

## The length in beats the pattern loops at: [member length_beats] here, the sum
## of its steps in a [PatternChain]. Read it through this, not [member length_beats].
func get_play_length() -> float:
	return length_beats

## Chainable helper for building patterns in code.
func add(p_beat: float, p_dur: float, p_index: int, p_oct: int = 0, p_acc: float = 0.0, p_vel: float = 0.8) -> MusicPattern:
	notes.append(PatternNote.create(p_beat, p_dur, p_index, p_oct, p_acc, p_vel))
	return self
