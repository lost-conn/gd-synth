@tool
class_name SynthPitchMap
extends RefCounted

# Pitch arithmetic for the Pattern view, mirroring MusicTrack's resolver
# (_resolve_chord_float / _resolve_melody_float) so what the roll shows is what
# the track plays, plus the inverse the "other tracks" overlay needs: a MIDI
# pitch back to the nearest row of a roll of another type.
#
# Rows mean different things per track type:
#   CHORD   chord-tone index; the block's chord size is one octave
#   MELODY  scale degree; the block's scale size is one octave
#   DRUM    an absolute MIDI note

const GM_DRUMS := {
	35: "Kick 2", 36: "Kick", 37: "Side stick", 38: "Snare", 39: "Clap", 40: "Snare 2",
	41: "Floor tom", 42: "Closed hat", 43: "Floor tom 2", 44: "Pedal hat", 45: "Low tom",
	46: "Open hat", 47: "Mid tom", 48: "Mid tom 2", 49: "Crash", 50: "High tom", 51: "Ride",
	52: "China", 53: "Ride bell", 54: "Tambourine", 55: "Splash", 56: "Cowbell", 57: "Crash 2",
	58: "Vibraslap", 59: "Ride 2", 60: "Hi bongo", 61: "Low bongo", 62: "Mute hi conga",
	63: "Open hi conga", 64: "Low conga", 65: "Hi timbale", 66: "Low timbale", 67: "Hi agogo",
	68: "Low agogo", 69: "Cabasa", 70: "Maracas", 71: "Short whistle", 72: "Long whistle",
	73: "Short guiro", 74: "Long guiro", 75: "Claves", 76: "Hi wood block", 77: "Low wood block",
	78: "Mute cuica", 79: "Open cuica", 80: "Mute triangle", 81: "Open triangle",
}
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const DEGREES := ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
const TONES := ["Root", "3rd", "5th", "7th", "9th"]

## Block of [param data] sounding at [param beat] (the progression loops).
static func block_at(data: MusicData, beat: float) -> MusicBlock:
	if data == null or data.blocks.is_empty():
		return null
	var total := 0.0
	for b in data.blocks:
		total += float(b.duration_beats)
	if total <= 0.0:
		return data.blocks[0]
	var t := fposmod(beat, total)
	for b in data.blocks:
		if t < float(b.duration_beats):
			return b
		t -= float(b.duration_beats)
	return data.blocks[0]

## Rows in one octave of [param type] in [param block]: the chord size, the scale
## size, 12 for drums. Falls back to 3 / 7 with no block.
static func rows_per_octave(type: int, block: MusicBlock) -> int:
	match type:
		MusicTrack.TrackType.CHORD:
			return maxi(1, block.chord_intervals.size()) if block != null else 3
		MusicTrack.TrackType.MELODY:
			return maxi(1, block.scale_intervals.size()) if block != null else 7
	return 12

## The row a note is drawn on: its index plus its octave offset (drums ignore octave).
static func display_row(type: int, index: int, octave: int, rpo: int) -> int:
	if type == MusicTrack.TrackType.DRUM:
		return index
	return index + octave * rpo

## Fractional MIDI pitch of (index, octave, accidental) as MusicTrack resolves it.
static func to_midi(type: int, index: int, octave: int, accidental: float, base_octave: int, block: MusicBlock) -> float:
	if type == MusicTrack.TrackType.DRUM:
		return float(index)
	if block == null:
		return 60.0
	var intervals: PackedInt32Array = block.chord_intervals if type == MusicTrack.TrackType.CHORD else block.scale_intervals
	var root: int = block.chord_root if type == MusicTrack.TrackType.CHORD else block.scale_root
	var size := intervals.size()
	if size == 0:
		return 60.0
	var extra_oct := floori(float(index) / float(size))
	return float(12 * (base_octave + 1 + octave + extra_oct) + root + intervals[posmod(index, size)]) + accidental

## The row of a roll of [param type] whose pitch is nearest to [param midi] in
## [param block]. An approximation: the accidental is rounded away, and a
## progression that changes chord size mid-pattern is read at one beat.
static func midi_to_row(type: int, midi: float, base_octave: int, block: MusicBlock) -> int:
	if type == MusicTrack.TrackType.DRUM:
		return roundi(midi)
	if block == null:
		return roundi(midi) - 60
	var intervals: PackedInt32Array = block.chord_intervals if type == MusicTrack.TrackType.CHORD else block.scale_intervals
	var root: int = block.chord_root if type == MusicTrack.TrackType.CHORD else block.scale_root
	var size := intervals.size()
	if size == 0:
		return 0
	var rel: float = midi - float(12 * (base_octave + 1) + root)
	var oct := floori(rel / 12.0)
	var within: float = rel - 12.0 * oct
	var best := 0
	var best_d := 1e9
	for d in size + 1:
		var iv: float = float(intervals[d]) if d < size else 12.0
		var dist := absf(iv - within)
		if dist < best_d - 0.0001:
			best_d = dist
			best = d
	return oct * size + best

# ---------------------------------------------------------------------------
# Row labels
# ---------------------------------------------------------------------------

## What a kit piece is called: its name, else the General MIDI drum or note name
## of its note ("Closed hat", "G3").
static func piece_name(piece: SynthKitPiece) -> String:
	if piece == null:
		return ""
	if piece.name != "":
		return piece.name
	return String(GM_DRUMS[piece.note]) if GM_DRUMS.has(piece.note) else note_name(piece.note)

## Row label of a drum row in a kit: "36 Kick" with the piece's name, or "" when
## no piece plays the row.
static func kit_label(kit: SynthKit, midi: int) -> String:
	var piece: SynthKitPiece = kit.get_piece_for_note(midi) if kit != null else null
	return "%d %s" % [midi, piece_name(piece)] if piece != null else ""

## Drum row label: "36 Kick", or the note name where General MIDI has no drum.
static func drum_label(midi: int) -> String:
	if GM_DRUMS.has(midi):
		return "%d %s" % [midi, GM_DRUMS[midi]]
	return "%d %s" % [midi, note_name(midi)]

static func note_name(midi: int) -> String:
	return "%s%d" % [NOTE_NAMES[posmod(midi, 12)], floori(midi / 12.0) - 1]

## Label of [param row] for a roll of [param type] with [param rpo] rows per octave.
static func row_label(type: int, row: int, rpo: int, kit: SynthKit = null) -> String:
	match type:
		MusicTrack.TrackType.DRUM:
			var named := kit_label(kit, row)
			return named if named != "" else drum_label(row)
		MusicTrack.TrackType.MELODY:
			var oct := floori(float(row) / float(rpo))
			var d := posmod(row, rpo)
			return (DEGREES[d] if d < DEGREES.size() else str(d + 1)) + _octave_suffix(oct)
		_:
			var oct := floori(float(row) / float(rpo))
			var d := posmod(row, rpo)
			return (TONES[d] if d < TONES.size() else "t%d" % d) + _octave_suffix(oct)

static func _octave_suffix(oct: int) -> String:
	if oct == 0:
		return ""
	return " +%d" % oct if oct > 0 else " %d" % oct

static func type_name(type: int) -> String:
	match type:
		MusicTrack.TrackType.CHORD:
			return "Chord"
		MusicTrack.TrackType.MELODY:
			return "Melody"
	return "Drum"
