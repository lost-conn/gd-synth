@tool
class_name MusicSection
extends Resource

# One part of a song (intro, verse, chorus...): a progression to play and what
# each MusicTrack does while it plays. See [MusicSong] for how sections are put
# in order and [MusicDataPlayer] for how they are played.
#
# Length in beats = the progression's length (the sum of its blocks'
# duration_beats) × [member repeats]. A section always ends on a progression
# boundary. A section with no progression of its own, in a song with none
# either, has no length and is skipped.

## Shown in the editor; [method MusicDataPlayer.play_from_section],
## [method MusicDataPlayer.set_loop_section] and
## [method MusicDataPlayer.queue_section] can find the section by it.
@export var name: String = ""

## The chord progression of this section. Null (or empty): the song's
## [member MusicSong.progression]. Only the blocks are used: the tempo is always
## the song's [member MusicSong.bpm], and this MusicData's own bpm is ignored.
@export var progression: MusicData

## How many times the progression plays in this section. Patterns are not
## restarted between repeats; they loop as they always do.
@export_range(1, 64, 1, "or_greater") var repeats: int = 1:
	set(value):
		repeats = maxi(1, value)

## What the tracks do in this section, one slot per track. A track without a
## slot behaves as [constant MusicSectionSlot.KEEP]: it carries on with
## whatever it was playing.
@export var slots: Array[MusicSectionSlot] = []

## The progression this section plays in [param song]: its own, else the song's.
## Null when neither has blocks.
func get_progression(song: MusicSong) -> MusicData:
	if progression != null and not progression.blocks.is_empty():
		return progression
	if song != null and song.progression != null and not song.progression.blocks.is_empty():
		return song.progression
	return null

## The section's length in beats when played in [param song] (0: no progression).
func get_length_beats(song: MusicSong) -> float:
	return progression_beats(get_progression(song)) * float(maxi(1, repeats))

## The slot for the track named [param track_name], or null (the track KEEPs).
## If several slots name the track, the last one counts.
func get_slot(track_name: StringName) -> MusicSectionSlot:
	var found: MusicSectionSlot = null
	for s in slots:
		if s != null and s.track == track_name:
			found = s
	return found

## Add a slot (chainable, for building sections in code).
func add_slot(track_name: StringName, mode: MusicSectionSlot.Mode = MusicSectionSlot.Mode.PLAY,
		pattern: MusicPattern = null) -> MusicSection:
	slots.append(MusicSectionSlot.create(track_name, mode, pattern))
	return self

## The sum of [param data]'s block durations (0 for null).
static func progression_beats(data: MusicData) -> float:
	if data == null:
		return 0.0
	var total: float = 0.0
	for b in data.blocks:
		if b != null:
			total += float(b.duration_beats)
	return total

static func create(p_name: String, p_progression: MusicData = null, p_repeats: int = 1) -> MusicSection:
	var s := MusicSection.new()
	s.name = p_name
	s.progression = p_progression
	s.repeats = p_repeats
	return s
