@tool
class_name SynthHarmony
extends RefCounted

# Names for the chords and scales a MusicBlock holds, and the tables the Track
# view's progression editor offers. A block stores plain semitone offsets, so a
# chord or scale is "named" by matching those offsets against MusicData's presets;
# anything else is "custom".

const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

## Chord qualities: [[suffix, menu text, intervals], ...]. The suffix is what a
## chord symbol appends to the root ("" major, "m" minor).
static func chord_table() -> Array:
	return [
		["", "Major", MusicData.CHORD_MAJ], ["m", "Minor", MusicData.CHORD_MIN],
		["dim", "Diminished", MusicData.CHORD_DIM], ["aug", "Augmented", MusicData.CHORD_AUG],
		["maj7", "Major 7th", MusicData.CHORD_MAJ7], ["m7", "Minor 7th", MusicData.CHORD_MIN7],
		["7", "Dominant 7th", MusicData.CHORD_DOM7], ["sus2", "Sus 2", MusicData.CHORD_SUS2],
		["sus4", "Sus 4", MusicData.CHORD_SUS4],
	]

## Scales: [[menu text, intervals], ...].
static func scale_table() -> Array:
	return [
		["Major", MusicData.MAJOR], ["Minor", MusicData.MINOR], ["Dorian", MusicData.DORIAN],
		["Phrygian", MusicData.PHRYGIAN], ["Lydian", MusicData.LYDIAN],
		["Mixolydian", MusicData.MIXOLYDIAN], ["Penta Major", MusicData.PENTA_MAJOR],
		["Penta Minor", MusicData.PENTA_MINOR], ["Blues", MusicData.BLUES],
		["Chromatic", MusicData.CHROMATIC],
	]

## Index into chord_table() of [param iv], or -1 for a chord that matches none.
static func chord_index(iv: PackedInt32Array) -> int:
	var t := chord_table()
	for i in t.size():
		if iv == t[i][2]:
			return i
	return -1

## Index into scale_table() of [param iv], or -1.
static func scale_index(iv: PackedInt32Array) -> int:
	var t := scale_table()
	for i in t.size():
		if iv == t[i][1]:
			return i
	return -1

## "m7" for a minor seventh, "*" for a chord that matches no preset.
static func chord_suffix(iv: PackedInt32Array) -> String:
	var i := chord_index(iv)
	return chord_table()[i][0] if i >= 0 else "*"

static func scale_name(iv: PackedInt32Array) -> String:
	var i := scale_index(iv)
	return scale_table()[i][0] if i >= 0 else "(custom scale)"

## "Dm" for a D minor block.
static func chord_name(b: MusicBlock) -> String:
	return NOTE_NAMES[posmod(b.chord_root, 12)] + chord_suffix(b.chord_intervals)

## "0, 4, 7, 9": intervals as the custom entry of a menu shows them.
static func intervals_text(iv: PackedInt32Array) -> String:
	var parts := PackedStringArray()
	for v in iv:
		parts.append(str(v))
	return ", ".join(parts)

## [param iv] as the set the custom editors author: sorted, without duplicates,
## always holding 0 (the root), and only offsets within 0..[param max_interval]
## (anything outside is dropped).
static func clean_intervals(iv: PackedInt32Array, max_interval: int) -> PackedInt32Array:
	var seen := {0: true}
	for v in iv:
		if v >= 0 and v <= max_interval:
			seen[v] = true
	var out := PackedInt32Array()
	for k in seen:
		out.append(k)
	out.sort()
	return out

## [param iv] with offset [param v] switched on or off, cleaned. The root (0) cannot
## be switched off.
static func toggled_intervals(iv: PackedInt32Array, v: int, max_interval: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var had := false
	for x in iv:
		if x == v and v != 0:
			had = true
		else:
			out.append(x)
	if not had:
		out.append(v)
	return clean_intervals(out, max_interval)

## Intervals typed as "0, 4, 7, 14" (commas, semicolons or spaces), cleaned. An
## empty array means the text is not a list of whole numbers in 0..[param max_interval].
static func parse_intervals(text: String, max_interval: int) -> PackedInt32Array:
	var parts := text.replace(",", " ").replace(";", " ").split(" ", false)
	var raw := PackedInt32Array()
	for p in parts:
		if not p.is_valid_int():
			return PackedInt32Array()
		var v := p.to_int()
		if v < 0 or v > max_interval:
			return PackedInt32Array()
		raw.append(v)
	if raw.is_empty():
		return PackedInt32Array()
	return clean_intervals(raw, max_interval)

## Total length of the progression in beats.
static func progression_beats(d: MusicData) -> int:
	var total := 0
	if d != null:
		for b in d.blocks:
			total += maxi(0, b.duration_beats)
	return total

## A short text that changes whenever anything a block or the tempo holds changes.
static func fingerprint(d: MusicData) -> String:
	if d == null:
		return ""
	var s := "%.4f|" % d.bpm
	for b in d.blocks:
		s += "%d:%s:%d:%s:%d;" % [b.chord_root, intervals_text(b.chord_intervals), b.scale_root,
				intervals_text(b.scale_intervals), b.duration_beats]
	return s
