@tool
class_name SynthKitPiece
extends Resource

# One drum of a SynthKit: the pattern row (MIDI note) that triggers it, the patch it
# plays through, and the pitch, gain and pan it is played with. A piece sits on its
# own synth channel (see MusicTrack.kit), so every piece keeps its own patch.

## What the piece is called in the editor ("Kick", "Closed hat"). Empty: the
## editor falls back to the General MIDI name of [member note].
@export var name: String = ""

## The pattern row that triggers this piece: a DRUM pattern's PatternNote.index
## (an absolute MIDI note number, 36 = C2 kick, 38 = snare, 42 = hi-hat).
@export_range(0, 127) var note: int = 36

## The timbre of this piece. Null: the channel keeps whatever patch it already has.
@export var patch: SynthPatch

## The MIDI note the patch is played at, which sets how its pitch-tracking
## oscillators sound. -1 (the default) plays it at [member note].
@export_range(-1, 127) var pitch: int = -1

## Multiplies the velocity of every note that triggers this piece (the result is
## clamped to 0..1). Balance the kit with it instead of editing the pattern.
@export_range(0.0, 4.0, 0.01, "or_greater") var gain: float = 1.0

## Stereo offset added to the track's pan (the sum is clamped to -1..1).
@export_range(-1.0, 1.0) var pan: float = 0.0

static func create(p_name: String, p_note: int, p_patch: SynthPatch = null, p_pitch: int = -1,
		p_gain: float = 1.0, p_pan: float = 0.0) -> SynthKitPiece:
	var p := SynthKitPiece.new()
	p.name = p_name
	p.note = p_note
	p.patch = p_patch
	p.pitch = p_pitch
	p.gain = p_gain
	p.pan = p_pan
	return p

## The MIDI note the patch is played at.
func get_pitch() -> int:
	return pitch if pitch >= 0 else note

## [param velocity] with [member gain] applied, clamped to 0..1.
func scale_velocity(velocity: float) -> float:
	return clampf(velocity * gain, 0.0, 1.0)

## [param track_pan] plus [member pan], clamped to -1..1.
func combined_pan(track_pan: float) -> float:
	return clampf(track_pan + pan, -1.0, 1.0)
