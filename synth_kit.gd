@tool
class_name SynthKit
extends Resource

# A drum kit: one DRUM pattern written in a single roll, one patch per drum.
#
# Set one on a MusicTrack (MusicTrack.kit) and the track plays each row of its
# pattern through the piece that owns that row: piece i of [member pieces] sits
# on synth channel (track.synth_channel + i), so the kit occupies the channels
# synth_channel .. synth_channel + pieces.size() - 1. A row no piece owns is
# silent. A song section can then swap one drums pattern instead of three.
#
# The bake follows the same routing: each piece's notes go to that piece's patch,
# at the piece's pitch and with its gain (see SynthSampleBaker.add_track_usage_routed
# and SynthBaker).

## The drums, in channel order. Two pieces with the same [member SynthKitPiece.note]:
## the first one plays that row.
@export var pieces: Array[SynthKitPiece] = []

## An empty kit, for the editor to fill.
static func make_default() -> SynthKit:
	return SynthKit.new()

## Index of the piece that plays pattern row [param n] (a note number), or -1.
func piece_for_note(n: int) -> int:
	for i in pieces.size():
		if pieces[i] != null and pieces[i].note == n:
			return i
	return -1

## The piece for row [param n], or null.
func get_piece_for_note(n: int) -> SynthKitPiece:
	var i := piece_for_note(n)
	return pieces[i] if i >= 0 else null

## How many synth channels the kit needs.
func channel_count() -> int:
	return pieces.size()

## The distinct patches of the pieces (a patch used twice once), in piece order.
func get_patches() -> Array[SynthPatch]:
	var out: Array[SynthPatch] = []
	for p in pieces:
		if p != null and p.patch != null and not out.has(p.patch):
			out.append(p.patch)
	return out

## What the kit says, as one string: it changes when a piece is added, removed or
## edited (a patch swapped, not edited inside), so a view can tell.
func signature() -> String:
	var s := ""
	for p in pieces:
		if p == null:
			s += "-;"
		else:
			s += "%s,%d,%d,%d,%.3f,%.3f,%d;" % [p.name, p.note, p.get_pitch(), p.pitch, p.gain, p.pan,
					p.patch.get_instance_id() if p.patch != null else 0]
	return s
