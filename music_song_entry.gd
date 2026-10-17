@tool
class_name MusicSongEntry
extends Resource

# One place in a MusicSong's running order: a section, played [member repeats]
# times in a row. Each repeat is a fresh start of the section (its PLAY slots
# restart their patterns and [signal MusicDataPlayer.section_changed] fires).

@export var section: MusicSection

@export_range(1, 64, 1, "or_greater") var repeats: int = 1:
	set(value):
		repeats = maxi(1, value)

static func create(p_section: MusicSection, p_repeats: int = 1) -> MusicSongEntry:
	var e := MusicSongEntry.new()
	e.section = p_section
	e.repeats = p_repeats
	return e
