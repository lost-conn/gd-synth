@tool
class_name MusicSectionSlot
extends Resource

# What one MusicTrack does during a MusicSection. The track is named, not
# referenced: MusicTracks are the instruments (nodes in a scene), sections and
# songs are content (resources), so a song can be shared by scenes whose tracks
# share names.
#
# A track the section has no slot for behaves as KEEP.

## What the track does when the section starts.
##   PLAY   — play [member pattern] from its beat 0 on the section's first beat.
##            The pattern restarts there even if the track was already playing
##            the same pattern, so a [PatternChain] begins at its first step.
##            The track is activated if it was not.
##   SILENT — stop the track: its sounding notes are released and it plays
##            nothing until a later section PLAYs it.
##   KEEP   — leave the track alone: it carries on with whatever it was playing
##            (or not playing), without restarting.
enum Mode { PLAY, SILENT, KEEP }

## The MusicTrack's node name.
@export var track: StringName

@export var mode: Mode = Mode.PLAY

## The pattern PLAY plays (a [PatternChain] is fine). Null plays the track's own
## [member MusicTrack.pattern], the one the scene gives it. Ignored by SILENT and
## KEEP.
@export var pattern: MusicPattern

static func create(p_track: StringName, p_mode: Mode = Mode.PLAY, p_pattern: MusicPattern = null) -> MusicSectionSlot:
	var s := MusicSectionSlot.new()
	s.track = p_track
	s.mode = p_mode
	s.pattern = p_pattern
	return s
