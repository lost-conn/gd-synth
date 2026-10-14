@tool
class_name SynthPreview
extends Node

# The editor tools' shared preview rig: ONE SynthEngine, ONE MusicDirector and
# ONE MusicTrack, built in code and owned by whoever adds this node (the Synth
# tab's main screen, or a standalone PatternEditor).
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

## The current patch (timbre). Null plays the default organ.
var patch: SynthPatch
## The MusicData being previewed, as chosen. Null = built-in default.
var music_data: MusicData
## False = play once through the progression (or the pattern, if longer), then
## stop. True = loop until stopped.
var loop: bool = true

var _suspended: bool = false
# Auditioned notes still held: midi -> the engine that started them.
var _held: Dictionary = {}
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
	if synth != null and not _suspended:
		synth.set_patch(CHANNEL, get_effective_patch())
		synth.all_notes_off()
	if sampler != null:
		sampler.all_notes_off()
	_held.clear()
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

## Notes of the audition that are still held: midi -> &"live" / &"baked".
func get_held_auditions() -> Dictionary:
	return _held.duplicate()

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

func is_playing() -> bool:
	return director != null and director.playing

## Play [param pattern] on the preview track, through the current patch and
## music data, from the top of the progression.
func play_pattern(pattern: MusicPattern, track_type: int, base_octave: int) -> void:
	if _suspended:
		return
	ensure_started()
	track.track_type = track_type
	track.pattern = pattern
	track.patch = get_effective_patch()
	track.synth_channel = CHANNEL
	track.base_octave = base_octave
	synth.set_patch(CHANNEL, get_effective_patch())
	track.activate()
	var data: MusicData = get_effective_music_data()
	director.data = data
	_end_beat = _one_shot_end_beat(data, pattern)
	director.play()
	_sync_playing()

func stop() -> void:
	if director != null:
		director.stop()
	if track != null:
		track.deactivate()
	if synth != null:
		synth.all_notes_off()
	if sampler != null:
		sampler.all_notes_off()
	_held.clear()
	_sync_playing()

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

# One pass over the progression, or over however many progressions the pattern
# needs to complete (a 8-beat pattern over a 4-beat progression takes two).
static func _one_shot_end_beat(data: MusicData, pattern: MusicPattern) -> float:
	var prog: float = 0.0
	for b in data.blocks:
		prog += float(b.duration_beats)
	if prog <= 0.0:
		return -1.0
	var pat: float = pattern.length_beats if pattern != null else 0.0
	return prog * maxf(1.0, ceilf(pat / prog - 0.0001))
