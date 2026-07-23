class_name SynthBaker
extends RefCounted

# Whole-track baking. Flattens a MusicData progression + a set of MusicTracks
# into a flat SynthEngine event timeline, then renders it offline to a single
# seamless looping AudioStreamWAV. Playing that WAV back costs ~zero CPU versus
# running the live synth voice-by-voice — the intended low-end-hardware path.
#
# Note resolution here mirrors MusicTrack/MusicDirector exactly (chord/scale
# degrees, octave stacking, swing, pitch bends, block progression) so a bake
# reproduces what the live system would have played. It does NOT capture Godot
# per-channel bus effects (e.g. a track's AudioEffectPhaser) — those are audio-
# server DSP applied downstream and aren't available offline. Route the baked
# player through the same bus at playback if you need bus-level effects.
#
# Typical use (editor or headless):
#   var song := SynthBaker.collect_song(main_music_node)   # {data, tracks, swing}
#   var wav := SynthBaker.bake_song(song.data, song.tracks, song.swing)
#   ResourceSaver.save(wav, "res://resources/audio/baked/bgm/main.wav")

const _TICKS := 480  # subdivisions per beat for exact loop-length LCM

## One track's contribution. `track_type` uses MusicTrack.TrackType values.
## Build these by hand or via [method collect_song].
class TrackInfo:
	var pattern: MusicPattern
	var patch: SynthPatch
	var track_type: int = MusicTrack.TrackType.MELODY
	var channel: int = 0
	var base_octave: int = 4
	var pan: float = 0.0

# ---------------------------------------------------------------------------
# Scene collection
# ---------------------------------------------------------------------------

## Walk [param root] (e.g. an instanced main_music scene) for a
## MusicDataPlayer's MusicData and every MusicTrack child, returning
## {data: MusicData, tracks: Array[TrackInfo], swing: float}. Reads exported
## properties directly — no _ready / tree membership required.
static func collect_song(root: Node, swing: float = 0.0) -> Dictionary:
	var data: MusicData = null
	var tracks: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MusicDataPlayer and data == null:
			data = (n as MusicDataPlayer).music_data
		elif n is MusicTrack:
			var t := n as MusicTrack
			var info := TrackInfo.new()
			info.pattern = t.pattern
			info.patch = t.patch
			info.track_type = int(t.track_type)
			info.channel = t.synth_channel
			info.base_octave = t.base_octave
			info.pan = t.pan
			tracks.append(info)
		for c in n.get_children():
			stack.push_back(c)
	return {"data": data, "tracks": tracks, "swing": swing}

# ---------------------------------------------------------------------------
# Baking
# ---------------------------------------------------------------------------

## Flatten + render a whole song to a seamless looping AudioStreamWAV.
static func bake_song(data: MusicData, tracks: Array, swing: float = 0.0,
		mix_rate: float = 22050.0, wrap_seconds: float = 1.0,
		seed: int = 1234) -> AudioStreamWAV:
	if data == null or data.blocks.is_empty():
		push_warning("[SynthBaker] No MusicData / empty progression.")
		return null

	var loop_beats := _loop_beats(data, tracks)
	var bpm: float = data.bpm if data.bpm > 0.0 else 120.0
	var spb: float = 60.0 / bpm  # seconds per beat
	var loop_seconds: float = loop_beats * spb

	var events: Array = []
	var patches: Array = []
	patches.resize(16)
	for info in tracks:
		if info == null or info.pattern == null or info.pattern.length_beats <= 0.0:
			continue
		if info.channel >= 0 and info.channel < 16:
			patches[info.channel] = info.patch
		_flatten_track(events, info, data, loop_beats, swing, spb, bpm)

	var synth := SynthEngine.new()
	var wav := synth.render_loop_offline(events, patches, loop_seconds, wrap_seconds, mix_rate, seed)
	synth.free()
	return wav

## Bake a single pattern+patch to a one-shot (or looping) AudioStreamWAV — the
## SFX bake path. CHORD/MELODY pitches resolve against [param block] (pass a
## fixed block, e.g. the song's tonic, since a baked SFX can't track live
## harmony); DRUM ignores it. One-shots run until the last note-off plus an
## envelope tail; set [param loop] for sustained SFX (rendered over one pattern
## length with a seamless wrap).
static func bake_pattern(pattern: MusicPattern, patch: SynthPatch, track_type: int,
		base_octave: int, block: MusicBlock, bpm: float, mix_rate: float = 22050.0,
		loop: bool = false, seed: int = 1234) -> AudioStreamWAV:
	if pattern == null or pattern.notes.is_empty() or pattern.length_beats <= 0.0:
		return null
	var spb: float = 60.0 / maxf(bpm, 1.0)

	var info := TrackInfo.new()
	info.track_type = track_type
	info.base_octave = base_octave
	info.channel = 0

	var events: Array = []
	var last_off: float = 0.0
	for note in pattern.notes:
		var midi: float = _resolve(track_type, block, base_octave, note.index, note.octave, note.accidental)
		var handle: int = roundi(midi)
		events.append([note.beat * spb, SynthEngine.CMD_NOTE_ON, 0, midi, note.velocity, 0.0])
		events.append([(note.beat + note.duration) * spb, SynthEngine.CMD_NOTE_OFF, 0, handle])
		last_off = maxf(last_off, note.beat + note.duration)
		if not note.bends.is_empty():
			_flatten_bends(events, info, block, handle, note.bends, note.beat, 0.0, spb)

	var synth := SynthEngine.new()
	var wav: AudioStreamWAV
	if loop:
		wav = synth.render_loop_offline(events, [patch], pattern.length_beats * spb, 1.0, mix_rate, seed)
	else:
		# Tail = envelope ring-out after the final note-off (patches are sustain=0,
		# so release dominates; noise_decay covers cymbal-like tails).
		var tail: float = clampf(patch.release + maxf(patch.decay, patch.noise_decay) + 0.15, 0.2, 3.0)
		wav = synth.render_offline(events, [patch], last_off * spb + tail, mix_rate, false, seed)
	synth.free()
	return wav

# Emit note-on/off (+ bend) events for one track across the whole loop.
static func _flatten_track(events: Array, info: TrackInfo, data: MusicData,
		loop_beats: float, swing: float, spb: float, bpm: float) -> void:
	var length: float = info.pattern.length_beats
	var reps: int = int(round(loop_beats / length))
	for rep in reps:
		var base_beat: float = rep * length
		for note in info.pattern.notes:
			var local: float = fposmod(_swung(note.beat, swing), length)
			var fire_beat: float = base_beat + local
			if fire_beat >= loop_beats - 1e-6:
				continue  # belongs to the next loop iteration
			var block := _block_at(data, fire_beat)
			var midi: float = _resolve(info.track_type, block, info.base_octave,
				note.index, note.octave, note.accidental)
			var handle: int = roundi(midi)
			events.append([fire_beat * spb, SynthEngine.CMD_NOTE_ON,
				info.channel, midi, note.velocity, info.pan])
			events.append([(fire_beat + note.duration) * spb, SynthEngine.CMD_NOTE_OFF,
				info.channel, handle])
			if not note.bends.is_empty():
				_flatten_bends(events, info, block, handle, note.bends, fire_beat, 0.0, spb)

static func _flatten_bends(events: Array, info: TrackInfo, block: MusicBlock,
		handle: int, bends: Array, parent_start: float, parent_offset: float, spb: float) -> void:
	for b in bends:
		var fire: float = parent_start + parent_offset + b.offset_beats
		var target_midi: float = _resolve(info.track_type, block, info.base_octave,
			b.index, b.octave, b.accidental)
		var target_freq: float = 440.0 * pow(2.0, (target_midi - 69.0) / 12.0)
		events.append([fire * spb, SynthEngine.CMD_BEND, info.channel, handle,
			target_freq, b.glide_beats * spb])
		if not b.bends.is_empty():
			_flatten_bends(events, info, block, handle, b.bends, parent_start,
				parent_offset + b.offset_beats, spb)

# ---------------------------------------------------------------------------
# Resolution helpers (mirror MusicTrack / MusicDirector)
# ---------------------------------------------------------------------------

static func _swung(beat: float, swing: float) -> float:
	if swing <= 0.0:
		return beat
	var eighth: float = beat * 2.0
	if int(floorf(eighth)) % 2 == 1:
		return beat + swing * 0.25
	return beat

# The MusicBlock active at absolute progression beat [param b].
static func _block_at(data: MusicData, b: float) -> MusicBlock:
	var total: float = 0.0
	for blk in data.blocks:
		total += float(blk.duration_beats)
	if total <= 0.0:
		return data.blocks[0]
	var pb: float = fposmod(b, total)
	var acc: float = 0.0
	for blk in data.blocks:
		if pb < acc + float(blk.duration_beats):
			return blk
		acc += float(blk.duration_beats)
	return data.blocks[data.blocks.size() - 1]

static func _resolve(track_type: int, block: MusicBlock, base_octave: int,
		index: int, octave: int, accidental: float) -> float:
	if track_type == MusicTrack.TrackType.DRUM:
		return float(index)
	var intervals: PackedInt32Array
	var root: int
	if track_type == MusicTrack.TrackType.CHORD:
		intervals = block.chord_intervals
		root = block.chord_root
	else:  # MELODY
		intervals = block.scale_intervals
		root = block.scale_root
	var size: int = intervals.size()
	if size == 0:
		return 60.0
	var idx: int = posmod(index, size)
	var extra_oct: int = int(floorf(float(index) / float(size)))
	return float(12 * (base_octave + 1 + octave + extra_oct) + root + intervals[idx]) + accidental

# Seamless loop length = LCM of the progression length and every pattern length,
# computed in integer ticks so fractional beats (e.g. 0.5) are exact.
static func _loop_beats(data: MusicData, tracks: Array) -> float:
	var prog: float = 0.0
	for blk in data.blocks:
		prog += float(blk.duration_beats)
	var acc: int = int(round(prog * _TICKS)) if prog > 0.0 else _TICKS
	for info in tracks:
		if info == null or info.pattern == null or info.pattern.length_beats <= 0.0:
			continue
		var t: int = int(round(info.pattern.length_beats * _TICKS))
		if t > 0:
			acc = _lcm(acc, t)
	return float(acc) / float(_TICKS)

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t: int = b
		b = a % b
		a = t
	return a

static func _lcm(a: int, b: int) -> int:
	if a == 0 or b == 0:
		return 0
	return a / _gcd(a, b) * b
