class_name SynthSampler
extends SynthEngine

# Plays baked SynthSampleSets through Godot's mixer instead of rendering voices
# in GDScript. A drop-in for SynthEngine as its callers use it: same channels,
# same note_on / note_off / bend_to / all_notes_off / set_patch, same bus
# routing, same master_gain / max_voices / configure / set_enabled. Put this
# script on the node in place of synth_engine.gd and nothing that drives it has
# to change.
#
# It extends SynthEngine only for that: so `var synth: SynthEngine` in
# MusicTrack, MidiPlayer and game code keeps accepting it, and so the channel
# auto-buses (ensure_channel_bus / release_channel_bus) are the engine's own
# code. Nothing of the live render path runs — no thread, no
# AudioStreamGenerator, no per-sample GDScript, no command queue: a call takes
# effect on the spot, on the main thread. (The inherited offline render_*
# methods still work, on the engine's own state.)
#
# How it plays. A pool of max_voices AudioStreamPlayers, one per voice.
# set_patch() resolves the patch to its baked set (see "Where sets come from");
# note_on() picks a sample from it and starts it on a free player, on the
# channel's bus, at the pitch_scale and volume SynthSampleSet asks for — the
# contract at the top of sample_set.gd is followed to the letter, and is where
# to look for what a sample can and cannot reproduce. After that the note costs
# nothing here: Godot mixes it. _process() only touches voices that are fading
# out after an early note_off or gliding after a bend_to, once a frame each.
#
# Why a player per voice and not an AudioStreamPolyphonic per channel: a release
# is a volume ramp, and AudioStreamPlaybackPolyphonic.set_stream_volume() takes
# effect as a step (Godot 4.7) — at one step a frame, a 100 ms release is six
# clicks. AudioStreamPlayer.volume_db is ramped by the mixer across each of its
# blocks, so a value set once a frame comes out as a continuous line.
#
# Where sets come from. A patch saved as its own file maps to
# <samples_dir>/<patch file name>.res, which is how the game's bake names them.
# A patch with no file of its own (built in code, or embedded in a scene) has no
# name to look up: hand its set over with set_patch_sample_set(). A patch with no
# set leaves its channel silent, with one warning; a set that is_stale() for its
# patch warns once and plays anyway unless allow_stale is off.
#
# What differs from the live engine (beyond what sample_set.gd lists):
#   • Pan is accepted and ignored: AudioStreamPlayer has none. Nothing in the
#     game pans today.
#   • A channel nobody called set_patch() on is silent. Live it plays the default
#     SynthPatch.
#   • mix_rate and buffer_length mean nothing here. configure() takes them and
#     only applies max_voices.
#   • Timing. Live, a command waits for the render thread and then for the
#     generator buffer (buffer_length); here it starts at the mixer's next block.
#     Sounds come out some tens of milliseconds sooner.
#   • Voices. The pool is the engine's — max_voices across all channels, oldest
#     stolen first — but a one-shot gives its voice back when its sample ends,
#     where the live voice of a decayed patch sits silent in the pool until its
#     note_off and release have run. So this steals less often. A stolen or cut
#     voice is faded over one mixer block by Godot rather than cut mid-sample.
#   • Release ramps and glides are driven at the frame rate. The mixer joins the
#     volume steps up into a line; a pitch step is a step (in pitch only — the
#     waveform stays continuous).
#
# Live mode. Set [member live] before the node enters the tree and every method
# of this script hands straight to SynthEngine's: the node is the plain live
# synth, thread and generators and all, and none of the sampler's state is built.
# It exists for comparing the two by ear without swapping scripts.

## Directory holding the baked sets, one per patch, named after the patch's
## file: resources/audio/patches/bass.tres plays <samples_dir>/bass.res.
@export_dir var samples_dir: String = "res://resources/audio/samples"

## Load every set in [member samples_dir] when the node enters the tree, and
## check each against its patch, so the first note of a sound does not wait on
## the disk. Off, a set is loaded the first time [method set_patch] meets its
## patch.
@export var preload_sets: bool = true

## Play a set whose patch has changed since it was baked (after warning once).
## Off, such a channel is silent until the set is re-baked.
@export var allow_stale: bool = true

## Run as the plain live [SynthEngine] instead of as a sampler (see "Live mode"
## above). Read when the node enters the tree; set it before then — from a
## subclass's _init(), say — and leave it alone afterwards.
var live: bool = false

# One sounding sample. Lives in _live from note_on until its stream ends, its
# release ramp runs out, or it is stolen / cut.
class SampleVoice:
	var channel: int = 0
	var note: int = 0  # rounded, as struck: the note_off / bend_to handle
	var sample_set: SynthSampleSet
	var sample: int = 0
	var player: AudioStreamPlayer
	var released: bool = false
	# Set when the voice has left _live, so _process drops it from _moving.
	var done: bool = false
	var moving: bool = false
	# Velocity (humanized) and linear volume it was struck at, for master_gain 1,
	# and what a release has made of that volume (SynthSampleSet.get_release_gain).
	var velocity: float = 1.0
	var volume: float = 1.0
	var ramp_gain: float = 1.0
	# Pitch now, fractional MIDI, and the pitch_scale that gives.
	var pitch: float = 60.0
	var scale: float = 1.0
	# Seconds into the sample at _now() == pos_clock. Advanced whenever the
	# pitch_scale changes, so a glide is accounted for.
	var pos: float = 0.0
	var pos_clock: float = 0.0
	# Release: _now() at note_on and at note_off (releasing while off_clock >= 0).
	var on_clock: float = 0.0
	var off_clock: float = -1.0
	# Glide: _now() when it began and how long it takes; 0 when not gliding.
	var glide_clock: float = 0.0
	var glide_len: float = 0.0
	var glide_from: float = 60.0
	var glide_to: float = 60.0

# Players not sounding a voice. Pool size is max_voices.
var _idle: Array[AudioStreamPlayer] = []
# Bus each channel's notes are started on (see set_channel_bus).
var _channel_bus_names: Array[StringName] = []
# Sample set per channel (null = silent), from the last set_patch on it.
var _channel_sets: Array[SynthSampleSet] = []
# Last take played per channel, so the next note gets a different one.
var _last_variant: PackedInt32Array = PackedInt32Array()
# Sounding voices, oldest first.
var _live: Array[SampleVoice] = []
# The voices of _live that are ramping or gliding — all _process looks at.
var _moving: Array[SampleVoice] = []
# SynthPatch -> SynthSampleSet (or null): the answer set_patch got the first
# time, so the lookup, the staleness hash and the warning happen once per patch.
var _patch_sets: Dictionary = {}
# Set file name (no extension) -> SynthSampleSet or null.
var _sets_by_name: Dictionary = {}
# What voice positions, releases and glides are timed by: real seconds (audio
# does not follow Engine.time_scale, so neither may this), summed up frame by
# frame so that it stops with the tree, as the players do. _clock is the time
# at the last _process; _now() adds what has passed since.
var _clock: float = 0.0
var _frame_usec: int = 0
# master_gain as the sounding voices have it.
var _applied_gain: float = -1.0

# Longest a frame is taken to be. A longer gap is the tree having been paused.
const _MAX_FRAME := 0.25
# A release shorter than this is left to the fade Godot gives a stopped player
# (one mixer block, about this long).
const _MIN_RAMP := 0.012
# Quietest a ramp sets a player to before it is stopped (-100 dB).
const _SILENCE := 0.00001

func _ready() -> void:
	if live:
		super._ready()
		return
	_channel_buses.resize(CHANNEL_COUNT)
	_channel_bus_names.resize(CHANNEL_COUNT)
	_channel_sets.resize(CHANNEL_COUNT)
	_patches.resize(CHANNEL_COUNT)
	_last_variant.resize(CHANNEL_COUNT)
	for ch in CHANNEL_COUNT:
		_channel_buses[ch] = &""
		_channel_bus_names[ch] = &"Master"
		_last_variant[ch] = -1
	_rng.randomize()
	_frame_usec = Time.get_ticks_usec()
	_applied_gain = master_gain
	_create_voice_players()
	if preload_sets:
		preload_sample_sets()

# Build the pool: max_voices players, all idle.
func _create_voice_players() -> void:
	for i in max_voices:
		var player := AudioStreamPlayer.new()
		player.name = "Voice%dPlayer" % i
		# Always Godot's own mixer, also where the platform default is to hand
		# samples to the browser: volume ramps, glides and bus effects need it.
		player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		add_child(player)
		_idle.append(player)

# ---------------------------------------------------------------------------
# Sample sets
# ---------------------------------------------------------------------------

## Load every set in [member samples_dir], and the patch each was baked from.
## Returns how many sets there are.
func preload_sample_sets() -> int:
	var count: int = 0
	for file in DirAccess.get_files_at(samples_dir):
		# An exported project may list a resource by its ".remap" stub.
		var f: String = file.trim_suffix(".remap")
		if f.get_extension() != "res" and f.get_extension() != "tres":
			continue
		var sample_set: SynthSampleSet = _load_set(f.get_basename())
		if sample_set == null:
			continue
		count += 1
		# Settle now which set its patch gets: hashing a patch to see whether
		# its set is stale is the slow part of a first set_patch().
		if ResourceLoader.exists(sample_set.source_patch):
			var patch: SynthPatch = load(sample_set.source_patch) as SynthPatch
			if patch != null:
				_resolve_set(patch)
	return count

## Use [param sample_set] for [param patch] from now on, whatever is in
## [member samples_dir] — the way in for a patch that has no file of its own.
## Takes effect at the next [method set_patch] with that patch.
func set_patch_sample_set(patch: SynthPatch, sample_set: SynthSampleSet) -> void:
	if patch != null:
		_patch_sets[patch] = sample_set

## The set [param channel] plays, or null if it is silent.
func get_channel_sample_set(channel: int) -> SynthSampleSet:
	if channel < 0 or channel >= CHANNEL_COUNT:
		return null
	return _channel_sets[channel]

## Forget which set every patch resolved to (and the loaded sets), so the next
## [method set_patch] looks again. For after a re-bake at runtime.
func clear_sample_set_cache() -> void:
	_patch_sets.clear()
	_sets_by_name.clear()

func _load_set(file_name: String) -> SynthSampleSet:
	if _sets_by_name.has(file_name):
		return _sets_by_name[file_name]
	var found: SynthSampleSet = null
	for ext in [".res", ".tres"]:
		var path: String = samples_dir.path_join(file_name + ext)
		if ResourceLoader.exists(path):
			found = load(path) as SynthSampleSet
			break
	_sets_by_name[file_name] = found
	return found

func _resolve_set(patch: SynthPatch) -> SynthSampleSet:
	if _patch_sets.has(patch):
		return _patch_sets[patch]
	var found: SynthSampleSet = null
	var path: String = patch.resource_path
	if path.is_empty() or path.contains("::"):
		push_warning("[SynthSampler] Patch '%s' is not a file of its own, so it has no baked set to look up — its channel is silent. Give it one with set_patch_sample_set()." % patch.patch_name)
	else:
		found = _load_set(path.get_file().get_basename())
		if found == null:
			push_warning("[SynthSampler] No sample set for %s in %s — its channel is silent. Bake it." % [path, samples_dir])
		elif found.size() == 0:
			push_warning("[SynthSampler] The sample set for %s is empty — its channel is silent." % path)
			found = null
		elif found.is_stale(patch):
			push_warning("[SynthSampler] The sample set for %s is stale: the patch has changed since it was baked. %s Re-bake it." % [
				path, "Playing it anyway." if allow_stale else "Its channel is silent."])
			if not allow_stale:
				found = null
	_patch_sets[patch] = found
	return found

# ---------------------------------------------------------------------------
# SynthEngine surface
# ---------------------------------------------------------------------------

## Point [param channel] at the baked set of [param patch]. Notes already
## sounding on the channel are left alone, as live.
func set_patch(channel: int, patch: SynthPatch) -> void:
	if live:
		super.set_patch(channel, patch)
		return
	if channel < 0 or channel >= CHANNEL_COUNT or patch == null:
		return
	_patches[channel] = patch
	_channel_sets[channel] = _resolve_set(patch)

## Start a note. [param pan] is ignored (see the top of this file).
func note_on(channel: int, note: float, velocity: float = 1.0, _pan: float = 0.0) -> void:
	if live:
		super.note_on(channel, note, velocity, _pan)
		return
	if not _enabled or channel < 0 or channel >= CHANNEL_COUNT:
		return
	var sample_set: SynthSampleSet = _channel_sets[channel]
	if sample_set == null:
		return

	# One pool for all channels, oldest out first — the engine's rule. A voice
	# whose sample has ended is not in the pool any more.
	_prune()
	while _live.size() >= max_voices:
		_stop_voice(_live[0])

	# Humanize as the engine does: pitch first, then velocity.
	var pitch: float = note
	if sample_set.pitch_randomize_cents > 0.0:
		pitch += (_rng.randf() * 2.0 - 1.0) * sample_set.pitch_randomize_cents / 100.0
	var vel: float = clampf(velocity, 0.0, 1.0)
	if sample_set.velocity_randomize > 0.0:
		vel *= lerpf(1.0 - sample_set.velocity_randomize, 1.0, _rng.randf())

	# A different take from the last one on this channel, otherwise at random.
	var variant: int = 0
	if sample_set.variants > 1:
		var last: int = _last_variant[channel]
		if last < 0:
			variant = _rng.randi() % sample_set.variants
		else:
			variant = (last + 1 + _rng.randi() % (sample_set.variants - 1)) % sample_set.variants
		_last_variant[channel] = variant

	var i: int = sample_set.find_sample(pitch, vel, variant)
	if i < 0:
		return
	# The samples carry the master_gain they were baked at; take it out, and
	# _apply_volume puts the engine's current one in.
	var volume: float = sample_set.get_volume(i, pitch, vel) / maxf(sample_set.master_gain, 1e-6)
	if volume <= 0.0 or _idle.is_empty():
		return

	var v := SampleVoice.new()
	v.channel = channel
	v.note = roundi(note)
	v.sample_set = sample_set
	v.sample = i
	v.player = _idle.pop_back()
	v.velocity = vel
	v.volume = volume
	v.pitch = pitch
	v.scale = sample_set.get_pitch_scale(i, pitch)
	v.on_clock = _now()
	v.pos_clock = v.on_clock
	_live.append(v)

	var player: AudioStreamPlayer = v.player
	player.stream = sample_set.streams[i]
	player.bus = _channel_bus_names[channel]
	player.pitch_scale = v.scale
	_apply_volume(v)
	player.play()

## Release the oldest unreleased voice of ([param channel], [param note]). A
## sample that has its own note-off in it, or has ended, is left to finish;
## anything else is taken to silence over the patch's release time.
func note_off(channel: int, note: int) -> void:
	if live:
		super.note_off(channel, note)
		return
	if not _enabled:
		return
	for v in _live:
		if v.released or v.channel != channel or v.note != note:
			continue
		v.released = true
		var sample_set: SynthSampleSet = v.sample_set
		if not sample_set.needs_release(v.sample, _position(v)):
			return
		if sample_set.release < _MIN_RAMP:
			_stop_voice(v)
			return
		v.off_clock = _now()
		_set_moving(v)
		return

## Glide the newest unreleased voice of ([param channel], [param source_midi])
## to [param target_freq] over [param glide_seconds]: a straight line in
## semitones, on the sample's pitch_scale. 0 seconds snaps. Calling again
## mid-glide carries on from where the pitch is.
func bend_to(channel: int, source_midi: int, target_freq: float, glide_seconds: float) -> void:
	if live:
		super.bend_to(channel, source_midi, target_freq, glide_seconds)
		return
	if not _enabled:
		return
	var k: int = _live.size() - 1
	while k >= 0:
		var v: SampleVoice = _live[k]
		k -= 1
		if v.released or v.channel != channel or v.note != source_midi:
			continue
		var target: float = 69.0 + 12.0 * log(maxf(target_freq, 0.0001) / 440.0) / log(2.0)
		if glide_seconds <= 0.0:
			v.glide_len = 0.0
			_set_pitch(v, target)
			return
		v.glide_from = v.pitch
		v.glide_to = target
		v.glide_clock = _now()
		v.glide_len = glide_seconds
		_set_moving(v)
		return

## Cut every voice, no release.
func all_notes_off() -> void:
	if live:
		super.all_notes_off()
		return
	if not _enabled:
		return
	_cut_all()

## Only [param p_max_voices] means anything to a sampler; the other two are the
## live engine's and are ignored. Changing the pool size drops the notes that
## are sounding, as the engine's configure() does.
func configure(_p_mix_rate: float, _p_buffer_length: float, p_max_voices: int) -> void:
	if live:
		super.configure(_p_mix_rate, _p_buffer_length, p_max_voices)
		return
	var voices: int = maxi(1, p_max_voices)
	if voices == max_voices:
		return
	max_voices = voices
	_cut_all()
	for player in _idle:
		remove_child(player)
		player.free()
	_idle.clear()
	_create_voice_players()

## Start [param channel]'s notes on [param bus] from now on, and move the ones
## that are sounding there.
func set_channel_bus(channel: int, bus: StringName) -> void:
	if live:
		super.set_channel_bus(channel, bus)
		return
	if channel < 0 or channel >= CHANNEL_COUNT:
		return
	_channel_bus_names[channel] = bus
	for v in _live:
		if v.channel == channel:
			v.player.bus = bus

func get_channel_bus(channel: int) -> StringName:
	if live:
		return super.get_channel_bus(channel)
	if channel < 0 or channel >= CHANNEL_COUNT:
		return &"Master"
	return _channel_bus_names[channel]

## Disabled, every voice is cut and notes are dropped until it is enabled again.
## Patches set meanwhile are kept.
func set_enabled(p_enabled: bool) -> void:
	if live:
		super.set_enabled(p_enabled)
		return
	if p_enabled == _enabled:
		return
	_enabled = p_enabled
	if not _enabled:
		_cut_all()

## Voices sounding right now (never more than [member max_voices]).
func get_voice_count() -> int:
	if live:
		var n: int = 0
		for v in _voices:
			if v.active:
				n += 1
		return n
	_prune()
	return _live.size()

# ---------------------------------------------------------------------------
# Voices
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if live:
		return
	var usec: int = Time.get_ticks_usec()
	var delta: float = minf(float(usec - _frame_usec) * 0.000001, _MAX_FRAME)
	_frame_usec = usec
	_clock += delta
	if master_gain != _applied_gain:
		# The engine multiplies every channel by master_gain on the way out, so
		# a tween on it fades what is already sounding.
		_applied_gain = master_gain
		for v in _live:
			_apply_volume(v)
	if _moving.is_empty():
		return
	var k: int = _moving.size() - 1
	while k >= 0:
		var v: SampleVoice = _moving[k]
		if v.done or not _advance(v, delta):
			v.moving = false
			_moving.remove_at(k)
		k -= 1

# One frame of a voice's glide and / or release ramp. Both aim half a frame
# ahead: the value set now is what the mixer plays until the next frame sets
# another. Returns false when the voice has nothing left to animate.
func _advance(v: SampleVoice, delta: float) -> bool:
	var busy: bool = false
	if v.glide_len > 0.0:
		var t: float = (_clock - v.glide_clock + 0.5 * delta) / v.glide_len
		if t >= 1.0:
			v.glide_len = 0.0
			_set_pitch(v, v.glide_to)
		else:
			# A straight line in semitones is the engine's exponential glide.
			_set_pitch(v, lerpf(v.glide_from, v.glide_to, t))
			busy = true
	if v.off_clock >= 0.0:
		var since: float = _clock - v.off_clock
		if since >= v.sample_set.release:
			_stop_voice(v)
			return false
		v.ramp_gain = v.sample_set.get_release_gain(v.sample, v.velocity,
				v.off_clock - v.on_clock, since + 0.5 * delta, _position(v) + 0.5 * delta * v.scale)
		_apply_volume(v)
		busy = true
	return busy

func _set_moving(v: SampleVoice) -> void:
	if not v.moving:
		v.moving = true
		_moving.append(v)

func _set_pitch(v: SampleVoice, pitch: float) -> void:
	v.pos = _position(v)
	v.pos_clock = _now()
	v.pitch = pitch
	v.scale = v.sample_set.get_pitch_scale(v.sample, pitch)
	v.player.pitch_scale = v.scale

func _apply_volume(v: SampleVoice) -> void:
	v.player.volume_db = linear_to_db(maxf(v.volume * v.ramp_gain * master_gain, _SILENCE))

# Seconds into its sample a voice is.
func _position(v: SampleVoice) -> float:
	return v.pos + (_now() - v.pos_clock) * v.scale

func _now() -> float:
	return _clock + minf(float(Time.get_ticks_usec() - _frame_usec) * 0.000001, _MAX_FRAME)

# Godot fades a stopped player out over one mixer block, on its own: the player
# is free for the next note straight away.
func _stop_voice(v: SampleVoice) -> void:
	v.player.stop()
	_idle.append(v.player)
	v.done = true
	_live.erase(v)

func _cut_all() -> void:
	for v in _live:
		v.player.stop()
		_idle.append(v.player)
		v.done = true
	_live.clear()

# Drop the voices whose sample has played out. (A player paused with the tree
# reports that it is not playing; its voice is still there when it resumes.)
func _prune() -> void:
	var k: int = _live.size() - 1
	while k >= 0:
		var v: SampleVoice = _live[k]
		if not v.player.playing and not v.player.stream_paused:
			_idle.append(v.player)
			v.done = true
			_live.remove_at(k)
		k -= 1
