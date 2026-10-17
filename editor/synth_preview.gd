@tool
class_name SynthPreview
extends Node

# The editor tools' shared preview rig: ONE SynthEngine, ONE MusicDirector and
# ONE MusicTrack, built in code and owned by whoever adds this node (the Synth
# tab's main screen, or a standalone PatternEditor).
#
# A whole song (the Track view's Play) uses the same engine and director with one
# more MusicTrack per lane, built by play_song(): see "Whole song" below. The
# single track above stays the Pattern view's. A scene whose player has a MusicSong
# is played by play_music_song(), through a real MusicDataPlayer over the same rig,
# so sections, slots, loops and seeks follow the game's own code.
#
# It never touches the game's /root/Synth or /root/Music autoloads: the track is
# handed its director and synth before it enters the tree and has autoplay off,
# so MusicTrack._ready does not go looking for the globals.
#
# What is shared through it:
#   - patch       the timbre on the preview channel. The patch editor edits it in
#                 place, so a held note or a looping pattern follows the edit.
#   - music_data  tempo + progression. Null means "use the built-in default"
#                 (see make_default_music_data), so play() always has something.
#   - the pattern being played (play_pattern).
#
# Auditioning single notes (the Sound view's keyboard) goes through the same rig:
# Live plays them on the SynthEngine above, Baked on a SynthSampler that is built
# the first time a baked note is asked for and plays the patch's SynthSampleSet
# (set_audition_set). Neither is the game's /root/Synth.
#
# The nodes are built on ensure_started(), not on _ready, so a tab nobody opens
# costs nothing. suspend()/resume() stop and restart the engine's render thread
# (the thread renders silence at full cost otherwise).

signal started
signal playing_changed(playing: bool)
signal patch_changed(patch: SynthPatch)
signal music_data_changed(data: MusicData)
## A note was auditioned. [param engine] is &"live" (SynthEngine), &"baked"
## (SynthSampler) or &"none" (baked asked for, no set to play).
signal audition_played(engine: StringName, note: int)

## Channel the preview track and the patch editor's test note share.
const CHANNEL := 0

var synth: SynthEngine
var director: MusicDirector
var track: MusicTrack
## Plays baked sets for the Sound view's Baked audition. Built on first use.
var sampler: SynthSampler
## The baked set of the current patch (null = none), for the Baked audition.
var audition_set: SynthSampleSet
## Which engine the most recent audition note went to (&"live" / &"baked" / &"none").
var last_audition_engine: StringName = &""
## The channel and MIDI note of the most recent kit audition ([method audition_kit_on]).
var last_kit_channel: int = -1
var last_kit_pitch: int = -1

## The current patch (timbre). Null plays the default organ.
var patch: SynthPatch
## The MusicData being previewed, as chosen. Null = built-in default.
var music_data: MusicData
## False = play once through the progression (or the pattern, if longer), then
## stop. True = loop until stopped.
var loop: bool = true

## The song's tracks while a whole song is on (play_song), one per lane in the
## order given. Empty otherwise.
var song_tracks: Array[MusicTrack] = []
## The real MusicDataPlayer playing a MusicSong over the preview's director and the
## song tracks (play_music_song). Built on first use, kept after Stop.
var song_player: MusicDataPlayer

var _suspended: bool = false
var _song_on: bool = false
var _music_song: MusicSong
var _song_end_beat: float = -1.0
var _song_audible: Array[bool] = []
# Auditioned notes still held: midi -> the engine that started them.
var _held: Dictionary = {}
# Kit pieces auditioned and still held: piece index -> MIDI note.
var _held_kit: Dictionary = {}
# True while the preview channels hold a kit's patches rather than the shared one.
var _kit_bound: bool = false
var _last_playing: bool = false
var _end_beat: float = -1.0
var _default_data: MusicData

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

## The fallback progression: 120 BPM, C major, a single C-major block.
static func make_default_music_data() -> MusicData:
	var d := MusicData.new()
	d.bpm = 120.0
	d.blocks = [MusicBlock.create(MusicData.C, MusicData.CHORD_MAJ, MusicData.C, MusicData.MAJOR, 4)]
	return d

## music_data if one was chosen, otherwise the built-in default. Never null.
func get_effective_music_data() -> MusicData:
	if music_data != null and not music_data.blocks.is_empty():
		return music_data
	if _default_data == null:
		_default_data = make_default_music_data()
	return _default_data

## True when the effective data is the fallback (nothing usable was chosen).
func is_using_default_data() -> bool:
	return music_data == null or music_data.blocks.is_empty()

func get_effective_patch() -> SynthPatch:
	if patch != null:
		return patch
	patch = SynthPatch.make_organ()
	return patch

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func is_started() -> bool:
	return synth != null

## Build the engine, director and track (once). Safe to call repeatedly.
func ensure_started() -> void:
	if synth != null:
		return
	synth = SynthEngine.new()
	synth.name = "PreviewSynth"
	synth.editor_preview = true
	add_child(synth)
	# The director must precede the track in the tree: its _process advances
	# the beat counter the track reads.
	director = MusicDirector.new()
	director.name = "PreviewDirector"
	director.editor_preview = true
	add_child(director)
	track = MusicTrack.new()
	track.name = "PreviewTrack"
	track.editor_preview = true
	# Pre-set the refs and turn autoplay off BEFORE add_child, so the track's
	# _ready never falls back to the global /root/Music and /root/Synth.
	track.director = director
	track.synth = synth
	track.autoplay = false
	track.synth_channel = CHANNEL
	add_child(track)
	if _suspended:
		synth.set_enabled(false)
	else:
		synth.set_patch(CHANNEL, get_effective_patch())
	started.emit()

## Stop playback and silence the engine's render thread. The nodes stay.
func suspend() -> void:
	if _suspended:
		return
	_suspended = true
	stop()
	if synth != null:
		synth.set_enabled(false)
	if sampler != null:
		sampler.set_enabled(false)

## Undo suspend(): restart the render thread and re-send the patch, since a
## set_patch while disabled is dropped by the engine.
func resume() -> void:
	if not _suspended:
		return
	_suspended = false
	if synth != null:
		synth.set_enabled(true)
		synth.set_patch(CHANNEL, get_effective_patch())
	if sampler != null:
		sampler.set_enabled(true)

func is_suspended() -> bool:
	return _suspended

## Stop everything and free the rig. After this ensure_started() builds a new one.
func shutdown() -> void:
	stop()
	_free_song_player()
	_free_song_tracks()
	for n in [track, director, synth, sampler]:
		if n != null and is_instance_valid(n):
			if n.get_parent() == self:
				remove_child(n)
			n.free()
	track = null
	director = null
	synth = null
	sampler = null
	_held.clear()
	_held_kit.clear()
	_kit_bound = false

func _exit_tree() -> void:
	if synth != null:
		stop()

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

## Make [param p] the current patch. A patch the editor is mutating in place
## needs no further call: the engine and the track hold the same object.
func set_patch(p: SynthPatch) -> void:
	if p == patch:
		return
	patch = p
	if track != null:
		track.patch = p
	# While a song plays, channel 0 belongs to whichever lane uses it.
	if synth != null and not _suspended and not _song_on:
		synth.set_patch(CHANNEL, get_effective_patch())
		synth.all_notes_off()
	if sampler != null:
		sampler.all_notes_off()
	_held.clear()
	_held_kit.clear()
	_kit_bound = false
	patch_changed.emit(p)

## Choose the MusicData to preview. Null selects the built-in default. A change
## while playing takes effect immediately.
func set_music_data(d: MusicData) -> void:
	if d == music_data:
		return
	music_data = d
	if director != null and director.playing:
		director.swap_data(get_effective_music_data(), MusicDirector.SwapMode.IMMEDIATE)
		_end_beat = -1.0
	music_data_changed.emit(d)

## The effective MusicData was edited in place (blocks added, removed, reordered).
## A director that is playing re-derives which block it is in, so it never points
## past the end of a shortened progression.
func progression_edited() -> void:
	if director != null and director.playing:
		director.seek(director.get_total_beats())

func set_pattern(p: MusicPattern) -> void:
	if track != null:
		track.pattern = p

func set_track_type(t: int) -> void:
	if track != null:
		track.track_type = t

func set_base_octave(o: int) -> void:
	if track != null:
		track.base_octave = o

# ---------------------------------------------------------------------------
# Auditioning single notes
# ---------------------------------------------------------------------------

## The sampler, built on first use. It never preloads the project's sets (the
## Sound view hands it the one it wants) and is inert unless it is this rig's.
func ensure_sampler() -> SynthSampler:
	if sampler != null:
		return sampler
	sampler = SynthSampler.new()
	sampler.name = "PreviewSampler"
	sampler.editor_preview = true
	sampler.preload_sets = false
	add_child(sampler)
	if _suspended:
		sampler.set_enabled(false)
	return sampler

## The baked set a Baked audition plays for the current patch. Null: nothing to play.
func set_audition_set(s: SynthSampleSet) -> void:
	audition_set = s
	if sampler != null:
		sampler.all_notes_off()
		_bind_audition_set()

func _bind_audition_set() -> void:
	var p: SynthPatch = get_effective_patch()
	sampler.set_patch_sample_set(p, audition_set)
	sampler.set_patch(CHANNEL, p)

## Start [param note] at [param velocity] on the live engine, or on the sampler
## with the patch's baked set when [param baked]. Returns which engine took it.
func audition_note_on(note: int, velocity: float, baked: bool = false) -> StringName:
	if _suspended:
		return &"none"
	ensure_started()
	_restore_shared_patch()
	var engine: StringName = &"live"
	if baked:
		if audition_set == null:
			engine = &"none"
		else:
			ensure_sampler()
			_bind_audition_set()
			sampler.note_on(CHANNEL, float(note), velocity)
			engine = &"baked"
	else:
		synth.note_on(CHANNEL, float(note), velocity)
	if engine != &"none":
		_held[note] = engine
	last_audition_engine = engine
	audition_played.emit(engine, note)
	return engine

## Release a note started by [method audition_note_on], on whichever engine took it.
func audition_note_off(note: int) -> void:
	var engine: StringName = _held.get(note, &"")
	_held.erase(note)
	if engine == &"live" and synth != null:
		synth.note_off(CHANNEL, note)
	elif engine == &"baked" and sampler != null:
		sampler.note_off(CHANNEL, note)

## Release every auditioned note that is still held.
func audition_all_off() -> void:
	for n in _held.keys():
		audition_note_off(n)
	for i in _held_kit.keys():
		audition_kit_off(i)

## Start piece [param i] of [param kit] at [param velocity] on the live engine: on
## channel CHANNEL + i, through the piece's patch, at the piece's pitch, with its
## gain and pan, as a MusicTrack with that kit would play it. Returns &"live", or
## &"none" when there is no such piece or its channel does not exist.
func audition_kit_on(kit: SynthKit, i: int, velocity: float) -> StringName:
	last_kit_channel = -1
	last_kit_pitch = -1
	if _suspended or kit == null or i < 0 or i >= kit.pieces.size() or kit.pieces[i] == null:
		return &"none"
	var ch: int = CHANNEL + i
	if ch >= SynthEngine.CHANNEL_COUNT:
		return &"none"
	ensure_started()
	var piece: SynthKitPiece = kit.pieces[i]
	if piece.patch != null:
		synth.set_patch(ch, piece.patch)
		_kit_bound = true
	var pitch: int = piece.get_pitch()
	synth.note_on(ch, float(pitch), piece.scale_velocity(velocity), piece.combined_pan(0.0))
	_held_kit[i] = pitch
	last_kit_channel = ch
	last_kit_pitch = pitch
	last_audition_engine = &"live"
	audition_played.emit(&"live", pitch)
	return &"live"

## Release a note started by [method audition_kit_on].
func audition_kit_off(i: int) -> void:
	if not _held_kit.has(i):
		return
	var pitch: int = _held_kit[i]
	_held_kit.erase(i)
	if synth != null:
		synth.note_off(CHANNEL + i, pitch)

# Put the shared patch back on the preview channel, after a kit used it.
func _restore_shared_patch() -> void:
	if _kit_bound and synth != null and not _suspended:
		synth.set_patch(CHANNEL, get_effective_patch())
	_kit_bound = false

## Notes of the audition that are still held: midi -> &"live" / &"baked".
func get_held_auditions() -> Dictionary:
	return _held.duplicate()

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

func is_playing() -> bool:
	return director != null and director.playing

## Play [param pattern] on the preview track, through the current patch and
## music data, from the top of the progression. [param kit]: a DRUM pattern's
## kit; each row then plays through its piece's patch (piece i on channel
## CHANNEL + i) instead of the current one.
func play_pattern(pattern: MusicPattern, track_type: int, base_octave: int, kit: SynthKit = null) -> void:
	if _suspended:
		return
	ensure_started()
	_stop_song_tracks()
	track.track_type = track_type
	track.pattern = pattern
	track.patch = get_effective_patch()
	track.kit = kit
	track.synth_channel = CHANNEL
	track.base_octave = base_octave
	synth.set_patch(CHANNEL, get_effective_patch())
	_kit_bound = track.uses_kit()
	track.activate()
	var data: MusicData = get_effective_music_data()
	director.data = data
	_end_beat = _one_shot_end_beat(data, pattern.get_play_length() if pattern != null else 0.0)
	director.play()
	_sync_playing()

# ---------------------------------------------------------------------------
# Whole song
# ---------------------------------------------------------------------------

## Play every lane in [param lanes] together through the current MusicData, each
## on its own channel with its own patch, from [param start_beat].
##
## A lane is a Dictionary: pattern (MusicPattern or null), type (MusicTrack.TrackType),
## patch (SynthPatch or null: the shared current patch), channel (0..15),
## kit (SynthKit or null: a DRUM lane's kit, whose pieces take channel + i),
## base_octave, pan, audible (false = muted: it is built but not activated).
##
## The song tracks are the preview's own, like the single one: handed their
## director and synth before they enter the tree, autoplay off. A lane's
## swap_mode and sync_to_director are not honoured: every lane starts at once, on
## the timeline, so that what the lanes draw is what is heard.
func play_song(lanes: Array, start_beat: float = 0.0) -> void:
	if _suspended:
		return
	ensure_started()
	stop()
	_free_song_tracks()
	_song_on = true
	_song_audible.clear()
	var longest := 0.0
	for spec in lanes:
		var t := MusicTrack.new()
		t.name = "SongTrack%d" % song_tracks.size()
		t.editor_preview = true
		t.director = director
		t.synth = synth
		t.autoplay = false
		t.track_type = int(spec.get("type", MusicTrack.TrackType.CHORD))
		t.pattern = spec.get("pattern")
		t.patch = spec.get("patch") if spec.get("patch") != null else get_effective_patch()
		t.synth_channel = clampi(int(spec.get("channel", 0)), 0, 15)
		t.base_octave = int(spec.get("base_octave", 4))
		t.pan = float(spec.get("pan", 0.0))
		t.kit = spec.get("kit")
		t.swap_mode = MusicDirector.SwapMode.IMMEDIATE
		# From the top, a lane starts its pattern the moment it is activated; from
		# the middle it has to follow the director's position.
		t.sync_to_director = start_beat > 0.001
		add_child(t)
		song_tracks.append(t)
		_song_audible.append(bool(spec.get("audible", true)))
		if t.pattern != null:
			longest = maxf(longest, t.pattern.get_play_length())
	var data: MusicData = get_effective_music_data()
	director.data = data
	for i in song_tracks.size():
		song_tracks[i].apply_patches()
		if _song_audible[i]:
			song_tracks[i].activate()
	_end_beat = _one_shot_end_beat(data, longest)
	director.play()
	if start_beat > 0.001:
		director.seek(start_beat)
	_sync_playing()

## True while a whole song is the thing playing.
func is_song_on() -> bool:
	return _song_on

## Silence or restore lane [param i] while the song plays (mute / solo).
## A lane that comes back joins on the timeline, not from its first note.
func set_song_lane_audible(i: int, audible: bool) -> void:
	if i < 0 or i >= song_tracks.size() or _song_audible[i] == audible:
		return
	_song_audible[i] = audible
	var t := song_tracks[i]
	if is_music_song_on():
		# The song decides what each track plays: a lane that comes back takes its
		# place by re-seeking the song where it is, and one that goes is just stopped.
		if audible:
			song_player.seek(director.get_total_beats())
		else:
			t.deactivate()
		return
	if audible:
		t.sync_to_director = true
		t.activate()
	else:
		t.deactivate()

## Change lane [param i] to [param spec] (same keys as play_song) without
## restarting the song: its notes are released and it rejoins on the timeline.
func update_song_lane(i: int, spec: Dictionary) -> void:
	if i < 0 or i >= song_tracks.size():
		return
	var t := song_tracks[i]
	t.deactivate()
	t.track_type = int(spec.get("type", t.track_type))
	t.pattern = spec.get("pattern")
	t.patch = spec.get("patch") if spec.get("patch") != null else get_effective_patch()
	t.synth_channel = clampi(int(spec.get("channel", 0)), 0, 15)
	t.base_octave = int(spec.get("base_octave", 4))
	t.pan = float(spec.get("pan", 0.0))
	t.kit = spec.get("kit")
	_song_audible[i] = bool(spec.get("audible", true))
	if synth != null and not _suspended:
		t.apply_patches()
	if _song_audible[i]:
		t.sync_to_director = true
		t.activate()

func is_song_lane_audible(i: int) -> bool:
	return i >= 0 and i < _song_audible.size() and _song_audible[i]

## Voices sounding now, per synth channel: {channel: count}. Released voices
## still ringing out count too; that is what the ear hears.
func active_voices_by_channel() -> Dictionary:
	var out := {}
	if synth == null:
		return out
	for v in synth._voices:
		if v.active:
			out[v.channel] = out.get(v.channel, 0) + 1
	return out

func _stop_song_tracks() -> void:
	_end_music_song()
	for t in song_tracks:
		if is_instance_valid(t):
			t.deactivate()
	if _song_on:
		_song_on = false
		if synth != null and not _suspended:
			synth.set_patch(CHANNEL, get_effective_patch())

func _free_song_tracks() -> void:
	for t in song_tracks:
		if is_instance_valid(t):
			if t.get_parent() == self:
				remove_child(t)
			t.free()
	song_tracks.clear()
	_song_audible.clear()

func stop() -> void:
	_end_music_song()
	if director != null:
		director.stop()
	if track != null:
		track.deactivate()
	for t in song_tracks:
		if is_instance_valid(t):
			t.deactivate()
	if _song_on:
		_song_on = false
		# The song may have put another lane's patch on channel 0.
		if synth != null and not _suspended:
			synth.set_patch(CHANNEL, get_effective_patch())
	if synth != null:
		synth.all_notes_off()
	if sampler != null:
		sampler.all_notes_off()
	_held.clear()
	_held_kit.clear()
	_restore_shared_patch()
	_sync_playing()

# ---------------------------------------------------------------------------
# Whole song, from a MusicSong
# ---------------------------------------------------------------------------

## Play [param song] with the real [MusicDataPlayer] over this rig: one MusicTrack per
## lane in [param lanes] (as for play_song, plus name: the MusicTrack's node name the
## sections' slots refer to, and active: whether the track is playing before the song
## touches it, the scene's autoplay), starting at entry [param entry], or at
## [param start_beat] of the song's timeline when that is given. Mute and solo
## (a lane's audible) keep a lane stopped whatever the song says.
func play_music_song(song: MusicSong, lanes: Array, entry: int = 0, start_beat: float = -1.0) -> void:
	if _suspended or song == null:
		return
	ensure_started()
	stop()
	_free_song_player()
	_free_song_tracks()
	_song_on = true
	_song_audible.clear()
	var used := {}
	for spec in lanes:
		var t := MusicTrack.new()
		var nm := String(spec.get("name", ""))
		t.name = nm if nm != "" and not used.has(nm) else "SongTrack%d" % song_tracks.size()
		used[nm] = true
		t.editor_preview = true
		t.director = director
		t.synth = synth
		t.autoplay = false
		t.track_type = int(spec.get("type", MusicTrack.TrackType.CHORD))
		t.pattern = spec.get("pattern")
		t.patch = spec.get("patch") if spec.get("patch") != null else get_effective_patch()
		t.synth_channel = clampi(int(spec.get("channel", 0)), 0, 15)
		t.base_octave = int(spec.get("base_octave", 4))
		t.pan = float(spec.get("pan", 0.0))
		t.kit = spec.get("kit")
		t.swap_mode = MusicDirector.SwapMode.IMMEDIATE
		# A track no section names plays on the timeline like the lane draws it; the
		# ones the song drives are started exactly by the player.
		t.sync_to_director = true
		add_child(t)
		song_tracks.append(t)
		_song_audible.append(bool(spec.get("audible", true)))
	for i in song_tracks.size():
		song_tracks[i].apply_patches()
		if bool(lanes[i].get("active", true)):
			song_tracks[i].activate()
	_music_song = song
	song_player = MusicDataPlayer.new()
	song_player.name = "SongPlayer"
	song_player.editor_preview = true
	song_player.director = director
	song_player.song = song
	song_player.section_changed.connect(_on_music_section_changed)
	add_child(song_player)
	_song_end_beat = song.get_length_beats()
	_end_beat = _song_end_beat
	song_player.play_from_section(entry)
	if start_beat >= 0.0 and not is_equal_approx(start_beat, song.entry_start(entry)):
		song_player.seek(start_beat)
	_sync_playing()

## True while a MusicSong plays through [member song_player].
func is_music_song_on() -> bool:
	return _song_on and song_player != null and is_instance_valid(song_player) and song_player.is_song_playing()

## The song [member song_player] plays now (null: none).
func get_music_song() -> MusicSong:
	return _music_song if is_music_song_on() else null

## Loop section [param which] (an entry index, as MusicDataPlayer.set_loop_section), or
## release it with -1. While one loops, the one-shot end of Loop-off does not stop it.
func set_loop_section(which: Variant) -> void:
	if not is_music_song_on():
		return
	song_player.set_loop_section(which)
	_end_beat = _song_end_beat if song_player.get_loop_section() == null else -1.0

# A section started: a muted or un-soloed lane stays stopped, whatever the section's
# PLAY slot just did to it.
func _on_music_section_changed(_section: MusicSection, _entry: int) -> void:
	for i in song_tracks.size():
		if not _song_audible[i] and is_instance_valid(song_tracks[i]):
			song_tracks[i].deactivate()

func _end_music_song() -> void:
	if song_player != null and is_instance_valid(song_player):
		song_player.stop()

func _free_song_player() -> void:
	if song_player != null and is_instance_valid(song_player):
		if song_player.get_parent() == self:
			remove_child(song_player)
		song_player.free()
	song_player = null
	_music_song = null

func _process(_delta: float) -> void:
	if director == null:
		return
	if director.playing and not loop and _end_beat > 0.0 \
			and director.get_total_beats() >= _end_beat:
		stop()
		return
	_sync_playing()

func _sync_playing() -> void:
	var now: bool = is_playing()
	if now != _last_playing:
		_last_playing = now
		playing_changed.emit(now)

# One pass over the progression, or over however many progressions a pattern of
# [param pattern_beats] needs to complete (a 8-beat pattern over a 4-beat
# progression takes two).
static func _one_shot_end_beat(data: MusicData, pattern_beats: float) -> float:
	var prog: float = 0.0
	for b in data.blocks:
		prog += float(b.duration_beats)
	if prog <= 0.0:
		return -1.0
	return prog * maxf(1.0, ceilf(pattern_beats / prog - 0.0001))
