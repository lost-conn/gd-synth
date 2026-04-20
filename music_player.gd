class_name MusicPlayer
extends Node

# Scene-embedded conductor for one arrangement. Collects its MusicTrack
# children, wires them to the global Synth / Music autoloads, and controls
# playback lifecycle.
#
# Typical usage: drop a MusicPlayer node in a scene, add MusicTrack
# children configured with patterns and patches, assign a MusicData
# resource, check autoplay. The global MusicDirector advances the beat;
# the player owns the track roster for this specific arrangement.
#
# Swapping themes: change music_data and call play() again. If the global
# Music is already playing, the progression hot-swaps according to swap_mode;
# otherwise playback starts fresh.

## MusicData (progression + bpm) pushed to the global MusicDirector when
## this player becomes active.
@export var music_data: MusicData

## Begin playback when this node enters the tree.
@export var autoplay: bool = false

## Hot-swap mode used when [method play] is called while the global
## MusicDirector is already playing. IMMEDIATE snaps to the new
## progression; NEXT_BEAT / NEXT_BLOCK defer the swap for a musical
## transition.
@export var swap_mode: MusicDirector.SwapMode = MusicDirector.SwapMode.NEXT_BLOCK

var _tracks: Array[MusicTrack] = []

func _ready() -> void:
	for child in get_children():
		if child is MusicTrack:
			_tracks.append(child)
			child.bind(Music, Synth)
	if autoplay:
		play()

func play() -> void:
	if music_data == null:
		push_warning("[MusicPlayer] music_data is null; nothing to play.")
		return
	if Music.playing:
		Music.swap_data(music_data, swap_mode)
	else:
		Music.data = music_data
		Music.play()

func stop() -> void:
	Music.stop()

func is_playing() -> bool:
	return Music.playing
