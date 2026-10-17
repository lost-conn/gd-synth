@tool
class_name MusicSong
extends Resource

# A whole piece of music as a running order of MusicSections. Played by a
# [MusicDataPlayer] whose [member MusicDataPlayer.song] is set; see that class
# for playback, looping one section and queueing sections from game code.
#
# Beats on the song's timeline count from 0 at the start of the first entry.
# One pass is every entry in order (each section's length × the entry's
# repeats); after the last entry the song continues from [member loop_entry],
# so the loop region is loop_entry .. the end.
#
# Tempo comes from the song only: the bpm of a section's (or the song's)
# MusicData is ignored.

## Tempo of the whole song, in beats per minute.
@export var bpm: float = 120.0

## Beats in a bar, for [constant MusicDataPlayer.NEXT_BAR] and the editor's
## timeline. Bars count from the start of the current section.
@export_range(1, 32, 1, "or_greater") var beats_per_bar: int = 4

## The progression every section without one of its own plays.
@export var progression: MusicData

## The running order.
@export var entries: Array[MusicSongEntry] = []

## The entry the song continues from after its last entry (clamped to the
## entries there are).
@export var loop_entry: int = 0

## Sections no entry plays that the game may queue
## ([method MusicDataPlayer.queue_section]). They are baked like the entries'
## sections; nothing else reads this.
@export var also_bake: Array[MusicSection] = []

## The length in beats of [param section] in this song (0: no progression).
func section_length(section: MusicSection) -> float:
	return section.get_length_beats(self) if section != null else 0.0

## The length in beats of entry [param i]: its section's length × its repeats.
func entry_length(i: int) -> float:
	if i < 0 or i >= entries.size() or entries[i] == null:
		return 0.0
	return section_length(entries[i].section) * float(maxi(1, entries[i].repeats))

## The beat entry [param i] starts on, in one pass from the top.
func entry_start(i: int) -> float:
	var acc: float = 0.0
	for k in mini(i, entries.size()):
		acc += entry_length(k)
	return acc

## The length in beats of one pass through every entry.
func get_length_beats() -> float:
	return entry_start(entries.size())

## [member loop_entry], clamped to the entries (0 for a song without any).
func get_loop_entry() -> int:
	return clampi(loop_entry, 0, maxi(entries.size() - 1, 0))

## The beat the loop region starts on.
func get_loop_start_beats() -> float:
	return entry_start(get_loop_entry())

## Where [param beat] of the song's timeline falls: {entry: int, section:
## MusicSection, repeat: int (of the entry, from 0), section_start: float,
## section_length: float, entry_start: float}. A beat past one pass is folded into
## the loop region, and the start beats it returns are then on [param beat]'s
## own scale (section_start <= beat < section_start + section_length). A negative
## beat counts as 0. Empty when the song has no length.
func entry_at_beat(beat: float) -> Dictionary:
	var total: float = get_length_beats()
	if total <= 0.0:
		return {}
	var b: float = maxf(beat, 0.0)
	var mapped: float = b
	if b >= total:
		var loop_start: float = get_loop_start_beats()
		var loop_len: float = total - loop_start
		if loop_len <= 0.0:
			return {}
		mapped = loop_start + fposmod(b - total, loop_len)
	var shift: float = b - mapped
	var acc: float = 0.0
	for i in entries.size():
		var elen: float = entry_length(i)
		if elen <= 0.0:
			continue
		if mapped < acc + elen or i == entries.size() - 1:
			var slen: float = section_length(entries[i].section)
			var r: int = clampi(int(floorf((mapped - acc) / slen)), 0, entries[i].repeats - 1)
			return {
				"entry": i,
				"section": entries[i].section,
				"repeat": r,
				"section_start": acc + float(r) * slen + shift,
				"section_length": slen,
				"entry_start": acc + shift,
			}
		acc += elen
	return {}

## The first section called [param section_name]: the entries' first, then
## [member also_bake]. Null if there is none.
func section_by_name(section_name: String) -> MusicSection:
	for e in entries:
		if e != null and e.section != null and e.section.name == section_name:
			return e.section
	for s in also_bake:
		if s != null and s.name == section_name:
			return s
	return null

## The first entry that plays [param section], or -1.
func entry_of(section: MusicSection) -> int:
	if section == null:
		return -1
	for i in entries.size():
		if entries[i] != null and entries[i].section == section:
			return i
	return -1

## Every section the song can play, each once, in order: the entries', then
## [member also_bake]'s.
func get_reachable_sections() -> Array[MusicSection]:
	var out: Array[MusicSection] = []
	for e in entries:
		if e != null and e.section != null and not out.has(e.section):
			out.append(e.section)
	for s in also_bake:
		if s != null and not out.has(s):
			out.append(s)
	return out

## Every progression the song can play, each once, in the order of
## [method get_reachable_sections].
func get_reachable_progressions() -> Array[MusicData]:
	var out: Array[MusicData] = []
	for s in get_reachable_sections():
		var d := s.get_progression(self)
		if d != null and not out.has(d):
			out.append(d)
	return out

## The progression an editor shows for the song as a whole: [member progression],
## else the first entry's section's. Null when there is none.
func get_display_progression() -> MusicData:
	if progression != null and not progression.blocks.is_empty():
		return progression
	for e in entries:
		if e != null and e.section != null:
			var d := e.section.get_progression(self)
			if d != null:
				return d
	return null

## Append an entry (chainable, for building songs in code).
func add_entry(section: MusicSection, repeats: int = 1) -> MusicSong:
	entries.append(MusicSongEntry.create(section, repeats))
	return self
