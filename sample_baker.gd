class_name SynthSampleBaker
extends RefCounted

# Multisample baking: a SynthPatch becomes a SynthSampleSet — single notes
# rendered through the offline engine, one per root, that a sampler pitches and
# scales instead of running the synth. See sample_set.gd for what the sampler
# does with the result; this file is how the samples are made.
#
# Typical use (editor or headless):
#   var usage := SynthSampleBaker.Usage.new()
#   SynthSampleBaker.add_pattern_usage(usage, pattern, track_type, octave, blocks, bpm)
#   var sample_set := SynthSampleBaker.bake(patch, usage)
#   ResourceSaver.save(sample_set, "res://resources/audio/samples/bass.res")
#   print(SynthSampleBaker.last_report)
#
# What a sample is. One voice, as the live engine puts it on its channel player:
# the patch's whole per-voice DSP, times SynthEngine.master_gain, through the
# channel's ±1 clip, at the velocity the game plays that note. Then normalised
# into 16 bits; the factor is recorded so the sampler can undo it.
#
# Two rates. The oscillator part is rendered at Settings.mix_rate (44.1 kHz —
# FM / additive patches alias at the live 22.05 kHz), in render blocks twice as
# long so the engine's control rate stays the live one. The noise part is not: the
# engine draws one random number per output sample and runs its one-pole noise
# filters per output sample, so noise rendered at 44.1 kHz has an extra octave
# on top and different filter corners. It is rendered at Settings.noise_rate
# (the live rate) and resampled up. The two parts can be rendered apart because
# everything after the mix point — the state-variable filter, the amp envelope,
# the gains — is linear; they are summed before the clip, which is not. A
# pure-noise patch is simply stored at the noise rate.
#
# Roots. A sample played off its root has everything in it time-scaled, and its
# noise and any filter resonance pitched. So roots are placed among the notes the
# patch is actually played at (Usage), never further than a semitone from one of
# them — and on every one of them when the patch has noise or a resonant peak.
#
# Gates. A decaying patch (sustain 0) released before its decay has finished
# rings on for its release time — in this engine often longer than the decay
# that was left. A held recording cannot give that back (a volume ramp can only
# shorten it), so such a note is recorded with the note-off where the game puts
# it, and the release is in the sample. Sustaining patches are recorded held,
# with a loop; their release is the sampler's ramp.
#
# Loops. See _plan_loop: whole cycles with the root retuned by a fraction of a
# cent so they fit the loop exactly; whole LFO cycles under vibrato; whole
# unison beat cycles when those are short enough; otherwise a crossfade.
#
# Takes. A patch with unison detune or noise sounds different on every note-on
# (random unison phases, fresh noise). One recording would freeze one of those,
# so such patches get Settings.variants takes per root (see _takes_for).

## Bumped whenever the baker would produce different samples from the same
## inputs. Part of [method bake_fingerprint].
const VERSION := 1

# Points in SynthSampleSet.velocity_curves (velocity 0, 1/8, ... 1).
const _CURVE_POINTS := 9
# Half-width, in input samples, of the windowed-sinc resampling kernel.
const _SINC_HALF := 24
# Frames stored past a loop's end, repeating its start. AudioStreamWAV plays the
# frame AT loop_end before it wraps (to loop_begin + 1), and interpolates into
# the ones after it when pitched — without them every pass of the loop ends on a
# frame of silence.
const _LOOP_TAIL := 8
# Largest FM period (in carrier cycles) still treated as periodic.
const _MAX_FM_PERIOD := 16

## Report of the most recent [method bake]:
##   name, kind ("one-shot" / "gated" / a loop kind), sustains, pitch_tracks
##   note_min, note_max      notes the patch is played at
##   roots                   Array of root notes baked
##   variants, layers        most takes / most velocity layers on any root
##   samples, bytes, seconds sample count, PCM bytes, total audio length
##   peak                    largest pre-clip peak of any sample, at the velocity
##                           it was baked at
##   peak_full               the same at velocity 1 — above 1, a single note of
##                           the patch clips its channel when hit as hard as it goes
##   clipped                 Array of root notes whose sample clipped
##   clipped_fraction        largest fraction of clipped frames in any sample
##   rate                    Hz the streams are stored at
##   gate                    longest baked gate (s), -1 if every sample is held
##   loop                    loop length in seconds of the first root (0 if none)
##   loop_fade               its crossfade in seconds (0 = exact loop)
##   seam                    worst loop seam: |jump across the seam| / largest
##                           step between neighbouring samples inside the loop
static var last_report: Dictionary = {}

## How a patch is played: the notes, the hardest and softest each is hit, and
## how long each is held. Fill with [method add_note] / the add_*_usage helpers.
class Usage:
	## midi (float, snapped to 1/1000) -> [max velocity, min velocity, longest gate s]
	var notes: Dictionary = {}
	## Smallest factor the game applies to note velocities at runtime
	## ([member MusicTrack.velocity_scale]). 0 for sounds that are attenuated all
	## the way down (distance falloff).
	var min_velocity_scale: float = 1.0
	## Largest bends seen, semitones from the struck note.
	var bend_up: float = 0.0
	var bend_down: float = 0.0

	func add_note(midi: float, velocity: float, gate_seconds: float) -> void:
		var key: float = snappedf(midi, 0.001)
		var vel: float = clampf(velocity, 0.0, 1.0)
		if notes.has(key):
			var e: Array = notes[key]
			e[0] = maxf(e[0], vel)
			e[1] = minf(e[1], vel)
			e[2] = maxf(e[2], gate_seconds)
		else:
			notes[key] = [vel, vel, gate_seconds]

	func add_bend(from_midi: float, to_midi: float) -> void:
		bend_up = maxf(bend_up, to_midi - from_midi)
		bend_down = maxf(bend_down, from_midi - to_midi)

	func is_empty() -> bool:
		return notes.is_empty()

	# Stable text form, for the bake fingerprint.
	func describe() -> String:
		var keys: Array = notes.keys()
		keys.sort()
		var parts: PackedStringArray = PackedStringArray()
		for k in keys:
			var e: Array = notes[k]
			parts.append("%.3f:%.4f:%.4f:%.5f" % [k, e[0], e[1], e[2]])
		return "%s|%.4f|%.3f|%.3f" % [",".join(parts), min_velocity_scale, bend_up, bend_down]

## Bake settings. The defaults are the decisions; override per patch only with a
## reason.
class Settings:
	## Rate (Hz) for the oscillator part.
	var mix_rate: float = 44100.0
	## Rate (Hz) for the noise part: the rate the live engine runs at, whose noise
	## timbre the patches were authored against.
	var noise_rate: float = 22050.0
	## The live engine's [member SynthEngine.master_gain] and
	## [member SynthEngine.loudness_compensation].
	var master_gain: float = 0.6
	var loudness_compensation: float = 1.0
	## Peak (linear) each sample is normalised to. 0.891 = -1 dBFS.
	var ceiling: float = 0.891
	## Takes per root for patches that are random per note (unison detune, noise).
	var variants: int = 2
	## A decaying unison note that runs through at least this many beat cycles
	## gets one take, not [member variants]: it passes through every phase the
	## voices can be in whichever one it starts at, so a second take is the same
	## sound shifted in time.
	var one_take_beats: float = 3.0
	## Furthest (semitones) a played note may be from the root that serves it.
	## 1 = ±6 % on pitch_scale, and so on every time baked into the sample
	## (envelopes, vibrato rate, unison beating) — small enough not to be heard
	## on a plain synth tone. 0 = every played note is its own root.
	var max_shift: float = 1.0
	## The same for patches with something in them that should not move with
	## pitch at all: noise, or a resonant filter peak.
	var fragile_shift: float = 0.0
	## Record decaying notes with the game's note-off (see "Gates" above). Off =
	## every one-shot is held to its natural end and the sampler ramps.
	var bake_gates: bool = true
	## Add a clean (just-under-the-clip) velocity layer to a note that clips at
	## the velocity it is baked at but is also played soft enough not to.
	var clean_layer: bool = true
	## Shortest loop (s) for a periodic tone.
	var min_loop_seconds: float = 0.05
	## A unison beat cycle up to this long (s) is looped whole; a longer one is
	## frozen in a short loop.
	var max_beat_seconds: float = 1.5
	## Loop length (s) and crossfade (s) for sustained noise and inharmonic FM.
	var noise_loop_seconds: float = 0.75
	var noise_fade_seconds: float = 0.1
	## Slack (s) after the envelopes have landed before a loop may start.
	var settle_seconds: float = 0.02
	var seed: int = 1234

	func describe() -> String:
		return "%d|%d|%.5f|%.4f|%.4f|%d|%.3f|%.3f|%.3f|%s|%s|%.4f|%.4f|%.4f|%.4f|%.4f|%d" % [
			int(mix_rate), int(noise_rate), master_gain, loudness_compensation, ceiling,
			variants, one_take_beats, max_shift, fragile_shift, bake_gates, clean_layer, min_loop_seconds,
			max_beat_seconds, noise_loop_seconds, noise_fade_seconds, settle_seconds, seed]

# ---------------------------------------------------------------------------
# Usage collection
# ---------------------------------------------------------------------------

## Add every note [param info] (a [SynthBaker.TrackInfo]) plays over one loop of
## [param data] — a director-driven track, resolved block by block as
## [SynthBaker] flattens it. A track that plays a kit has one patch per piece, so
## its notes belong in several usages: use [method add_track_usage_routed] (this
## one adds nothing for a kit track).
static func add_track_usage(usage: Usage, info, data: MusicData, swing: float = 0.0) -> void:
	if info == null or info.pattern == null or info.pattern.get_play_length() <= 0.0:
		return
	if _kit_of(info) != null:
		push_warning("[SynthSampleBaker] add_track_usage does not take a kit track: use add_track_usage_routed.")
		return
	if data == null or data.blocks.is_empty():
		return
	var spb: float = 60.0 / (data.bpm if data.bpm > 0.0 else 120.0)
	var loop_beats: float = SynthBaker._loop_beats(data, [info])
	var length: float = info.pattern.get_play_length()
	for rep in int(round(loop_beats / length)):
		for note in info.pattern.get_play_notes():
			var fire: float = rep * length + fposmod(SynthBaker._swung(note.beat, swing), length)
			var block := SynthBaker._block_at(data, fire)
			_add_note_usage(usage, note, info.track_type, info.base_octave, block, spb)

## [method add_track_usage] for a track that may play a kit. [param usage_for] is
## a Callable taking a [SynthPatch] and returning the [Usage] to add that patch's
## notes to (it may create the usage on first sight). A plain track adds all its
## notes to [code]usage_for(info.patch)[/code]; a kit track adds each piece's notes
## to [code]usage_for(piece.patch)[/code], at the piece's pitch and with its gain
## applied to the velocity, as [SynthBaker] renders them. Rows no piece owns and
## pieces without a patch add nothing.
static func add_track_usage_routed(info, data: MusicData, swing: float, usage_for: Callable) -> void:
	if info == null or info.pattern == null or info.pattern.get_play_length() <= 0.0:
		return
	if data == null or data.blocks.is_empty():
		return
	var kit: SynthKit = _kit_of(info)
	if kit == null:
		if info.patch != null:
			add_track_usage(usage_for.call(info.patch), info, data, swing)
		return
	var spb: float = 60.0 / (data.bpm if data.bpm > 0.0 else 120.0)
	var loop_beats: float = SynthBaker._loop_beats(data, [info])
	var length: float = info.pattern.get_play_length()
	var usages: Dictionary = {}  # piece index -> Usage
	for rep in int(round(loop_beats / length)):
		for note in info.pattern.get_play_notes():
			var i: int = kit.piece_for_note(note.index)
			if i < 0 or kit.pieces[i].patch == null or info.channel + i >= 16:
				continue
			if not usages.has(i):
				usages[i] = usage_for.call(kit.pieces[i].patch)
			var piece: SynthKitPiece = kit.pieces[i]
			var pitch: float = float(piece.get_pitch())
			var usage: Usage = usages[i]
			usage.add_note(pitch, piece.scale_velocity(note.velocity), note.duration * spb)
			_add_bend_usage(usage, pitch, note.bends, MusicTrack.TrackType.DRUM, info.base_octave, null,
					float(piece.get_pitch() - piece.note))

# The kit a track info plays, or null (not a DRUM track, or no kit).
static func _kit_of(info) -> SynthKit:
	var kit: Variant = info.get("kit")
	if kit is SynthKit and int(info.track_type) == MusicTrack.TrackType.DRUM:
		return kit
	return null

## [method add_pattern_usage] for a free-running DRUM pattern played through a
## [SynthKit]: each piece's notes go to [code]usage_for(piece.patch)[/code] (see
## [method add_track_usage_routed]), at the piece's pitch and gain. [param bpm] is
## the slowest tempo the pattern is played at.
static func add_kit_pattern_usage(pattern: MusicPattern, kit: SynthKit, bpm: float, usage_for: Callable) -> void:
	if pattern == null or kit == null:
		return
	var spb: float = 60.0 / maxf(bpm, 1.0)
	var usages: Dictionary = {}  # piece index -> Usage
	for note in pattern.get_play_notes():
		var i: int = kit.piece_for_note(note.index)
		if i < 0 or kit.pieces[i].patch == null:
			continue
		if not usages.has(i):
			usages[i] = usage_for.call(kit.pieces[i].patch)
		var piece: SynthKitPiece = kit.pieces[i]
		var pitch: float = float(piece.get_pitch())
		var usage: Usage = usages[i]
		usage.add_note(pitch, piece.scale_velocity(note.velocity), note.duration * spb)
		_add_bend_usage(usage, pitch, note.bends, MusicTrack.TrackType.DRUM, 4, null, float(piece.get_pitch() - piece.note))

## Add every note of a free-running pattern (an SFX on its own
## [member MusicTrack.bpm_override] clock). CHORD / MELODY pitches are resolved
## against each of [param blocks], since such a track can fire under any of
## them; DRUM ignores them. [param bpm] is the slowest tempo the pattern is
## played at — the one that holds its notes longest.
static func add_pattern_usage(usage: Usage, pattern: MusicPattern, track_type: int,
		base_octave: int, blocks: Array, bpm: float) -> void:
	if pattern == null:
		return
	var spb: float = 60.0 / maxf(bpm, 1.0)
	var ctx: Array = blocks
	if track_type == MusicTrack.TrackType.DRUM or ctx.is_empty():
		ctx = [null]
	for note in pattern.get_play_notes():
		for block in ctx:
			_add_note_usage(usage, note, track_type, base_octave, block, spb)

static func _add_note_usage(usage: Usage, note: PatternNote, track_type: int,
		base_octave: int, block: MusicBlock, spb: float) -> void:
	var midi: float = _resolve(track_type, block, base_octave, note.index, note.octave, note.accidental)
	usage.add_note(midi, note.velocity, note.duration * spb)
	_add_bend_usage(usage, midi, note.bends, track_type, base_octave, block)

static func _add_bend_usage(usage: Usage, midi: float, bends: Array, track_type: int,
		base_octave: int, block: MusicBlock, pitch_shift: float = 0.0) -> void:
	for b in bends:
		usage.add_bend(midi, _resolve(track_type, block, base_octave, b.index, b.octave, b.accidental) + pitch_shift)
		if not b.bends.is_empty():
			_add_bend_usage(usage, midi, b.bends, track_type, base_octave, block, pitch_shift)

# SynthBaker._resolve, tolerating the null block a track resolves to 60 against.
static func _resolve(track_type: int, block: MusicBlock, base_octave: int,
		index: int, octave: int, accidental: float) -> float:
	if block == null and track_type != MusicTrack.TrackType.DRUM:
		return 60.0
	return SynthBaker._resolve(track_type, block, base_octave, index, octave, accidental)

# ---------------------------------------------------------------------------
# Baking
# ---------------------------------------------------------------------------

## Fingerprint of a bake that has not been made yet: compare with a saved set's
## [member SynthSampleSet.bake_fingerprint] to tell whether re-baking
## [param patch] for [param usage] would change anything.
static func bake_fingerprint(patch: SynthPatch, usage: Usage, settings: Settings = null) -> String:
	var s: Settings = settings if settings != null else Settings.new()
	return ("%d\n%s\n%s\n%s" % [VERSION, SynthSampleSet.fingerprint_patch(patch),
		usage.describe(), s.describe()]).sha256_text()

## Bake [param patch] for the notes in [param usage]. Returns null (with a
## warning) when there is nothing to bake. Fills [member last_report].
static func bake(patch: SynthPatch, usage: Usage, settings: Settings = null) -> SynthSampleSet:
	last_report = {}
	if patch == null or usage == null or usage.is_empty():
		push_warning("[SynthSampleBaker] Nothing to bake (no patch / no notes).")
		return null
	var s: Settings = settings if settings != null else Settings.new()

	# Humanization is the sampler's job per note_on; baked in, it would freeze.
	var base: SynthPatch = patch.duplicate()
	base.pitch_randomize_cents = 0.0
	base.velocity_randomize = 0.0

	var pure_noise: bool = patch.noise_mix >= 1.0
	var variants: int = 1

	var sample_set := SynthSampleSet.new()
	sample_set.patch_name = patch.patch_name
	sample_set.source_patch = patch.resource_path
	sample_set.patch_fingerprint = SynthSampleSet.fingerprint_patch(patch)
	sample_set.bake_fingerprint = bake_fingerprint(patch, usage, s)
	sample_set.baker_version = VERSION
	sample_set.mix_rate = int(s.mix_rate)
	sample_set.noise_rate = int(s.noise_rate)
	sample_set.master_gain = s.master_gain
	sample_set.loudness_compensation = s.loudness_compensation
	sample_set.attack = patch.attack
	sample_set.decay = patch.decay
	sample_set.sustain = patch.sustain
	sample_set.release = patch.release
	sample_set.sustains = patch.sustain > 0.0
	sample_set.pitch_tracks = not pure_noise
	sample_set.pitch_randomize_cents = patch.pitch_randomize_cents
	sample_set.velocity_randomize = patch.velocity_randomize
	sample_set.max_bend_up = usage.bend_up
	sample_set.max_bend_down = usage.bend_down

	var roots: Array = _choose_roots(patch, usage, s)
	var report_roots: Array = []
	var clipped_roots: Array = []
	var peak: float = 0.0
	var peak_full: float = 0.0
	var clipped_fraction: float = 0.0
	var seconds: float = 0.0
	var layers: int = 1
	var longest_gate: float = -1.0
	var worst_seam: float = 0.0
	var loop_seconds: float = 0.0
	var loop_fade: float = 0.0
	var rate: int = 0
	var kinds: PackedStringArray = PackedStringArray()

	for root in roots:
		var takes: Array = []
		var take_peak: float = 0.0
		var count: int = _takes_for(base, root, s)
		variants = maxi(variants, count)
		for variant in count:
			var take: Dictionary = _render_take(base, root["note"], root["gate"],
				_take_seed(s.seed, variant, count, base), s)
			take_peak = maxf(take_peak, _peak(take["buf"]))
			takes.append(take)
		if take_peak <= 0.0:
			continue  # a silent note has nothing to play back
		peak_full = maxf(peak_full, take_peak)

		# Velocity layers. One, at the hardest the note is hit — unless that
		# clips and the note is also played softly enough that it would not.
		var vel_ref: float = root["velocity"]
		var vels: Array = [vel_ref]
		var clip_velocity: float = 1.0 / take_peak
		if s.clean_layer and vel_ref > clip_velocity * 1.001 \
				and root["min_velocity"] < clip_velocity * 0.98:
			vels = [clip_velocity, vel_ref]
		layers = maxi(layers, vels.size())

		for vel in vels:
			for variant in count:
				var take: Dictionary = takes[variant]
				var done: Dictionary = _finish_take(take, vel, s)
				sample_set.streams.append(done["stream"])
				sample_set.root_pitches.append(take["pitch"])
				sample_set.variant_ids.append(variant)
				sample_set.velocities.append(vel)
				sample_set.gains.append(done["gain"])
				sample_set.gates.append(take["gate"])
				sample_set.preclip_peaks.append(done["peak"])
				sample_set.clipped_fractions.append(done["clipped_fraction"])
				sample_set.velocity_curves.append(done["curve"])
				if take["kind"] != "" and not kinds.has(take["kind"]):
					kinds.append(take["kind"])
				peak = maxf(peak, done["peak"])
				clipped_fraction = maxf(clipped_fraction, done["clipped_fraction"])
				seconds += done["stream"].get_length()
				longest_gate = maxf(longest_gate, take["gate"])
				worst_seam = maxf(worst_seam, done["seam"])
				rate = int(take["rate"])
				if loop_seconds <= 0.0 and take["loop_end"] > 0:
					loop_seconds = float(take["loop_end"] - take["loop_begin"]) / take["rate"]
					loop_fade = float(take["fade"]) / take["rate"]
				if done["peak"] > 1.0 and not clipped_roots.has(root["note"]):
					clipped_roots.append(root["note"])
		report_roots.append(root["note"])

	sample_set.variants = variants
	sample_set.loop_kind = "/".join(kinds)
	if sample_set.streams.is_empty():
		push_warning("[SynthSampleBaker] %s rendered silent — no samples." % patch.patch_name)
		return null

	var keys: Array = usage.notes.keys()
	keys.sort()
	var kind: String = sample_set.loop_kind
	if kind == "":
		kind = "gated" if longest_gate >= 0.0 else "one-shot"
	last_report = {
		"name": patch.patch_name,
		"kind": kind,
		"sustains": sample_set.sustains,
		"pitch_tracks": sample_set.pitch_tracks,
		"note_min": keys[0],
		"note_max": keys[keys.size() - 1],
		"roots": report_roots,
		"variants": variants,
		"layers": layers,
		"samples": sample_set.streams.size(),
		"bytes": sample_set.get_data_bytes(),
		"seconds": seconds,
		"peak": peak,
		"peak_full": peak_full,
		"clipped": clipped_roots,
		"clipped_fraction": clipped_fraction,
		"rate": rate,
		"gate": longest_gate,
		"loop": loop_seconds,
		"loop_fade": loop_fade,
		"seam": worst_seam,
	}
	return sample_set

# ---------------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------------

# Roots to bake, ascending: [{note, velocity, min_velocity, gate}]. Played notes
# are grouped greedily into runs no wider than twice the patch's tolerance, and
# each run gets one root in its middle — on a played note when there is one
# there. With a tolerance of 0 every played note is a root.
static func _choose_roots(patch: SynthPatch, usage: Usage, s: Settings) -> Array:
	var keys: Array = usage.notes.keys()
	keys.sort()
	var floor_scale: float = usage.min_velocity_scale * (1.0 - patch.velocity_randomize)
	var fragile: bool = patch.noise_mix > 0.0 \
		or (patch.filter_type != SynthPatch.FilterType.OFF and patch.filter_resonance >= 0.3)
	var tolerance: float = maxf(s.fragile_shift if fragile else s.max_shift, 0.0)
	var roots: Array = []
	var i: int = 0
	while i < keys.size():
		var lo: float = keys[i]
		var hi: float = lo
		var e: Array = usage.notes[lo]
		var root := {"note": lo, "velocity": e[0], "min_velocity": e[1] * floor_scale, "gate": e[2]}
		i += 1
		while i < keys.size() and float(keys[i]) <= lo + 2.0 * tolerance + 1e-6:
			var o: Array = usage.notes[keys[i]]
			hi = keys[i]
			root["velocity"] = maxf(root["velocity"], o[0])
			root["min_velocity"] = minf(root["min_velocity"], o[1] * floor_scale)
			root["gate"] = maxf(root["gate"], o[2])
			i += 1
		if hi > lo:
			# Whole notes only when the run is of whole notes: a root between
			# two keys would be a pitch nobody plays.
			var mid: float = (lo + hi) * 0.5
			root["note"] = floorf(mid + 0.5) if is_equal_approx(lo, roundf(lo)) else mid
		roots.append(root)
	return roots

# Takes to record of one root. A deterministic patch needs one. A random one
# gets Settings.variants — except a decaying unison note long enough to run
# through Settings.one_take_beats beat cycles (see there).
static func _takes_for(patch: SynthPatch, root: Dictionary, s: Settings) -> int:
	var detuned: bool = patch.detune_voices > 1 and patch.detune_cents != 0.0
	if patch.noise_mix <= 0.0 and not detuned:
		return 1
	var takes: int = maxi(s.variants, 1)
	if patch.noise_mix > 0.0 or patch.sustain > 0.0:
		return takes
	var length: float = maxf(patch.attack, 0.0) + maxf(patch.decay, 0.0)
	if s.bake_gates and root["gate"] >= 0.0 and root["gate"] < length:
		length = root["gate"] + maxf(patch.release, 0.0)
	return 1 if length * _beat_rate(patch, root["note"]) >= s.one_take_beats else takes

# Beats per second between neighbouring unison voices of [param patch] at
# [param note]; 0 when it has no detuned unison.
static func _beat_rate(patch: SynthPatch, note: float) -> float:
	if patch.detune_voices <= 1 or patch.detune_cents == 0.0:
		return 0.0
	var f: float = 440.0 * pow(2.0, (note - 69.0) / 12.0)
	var step: float = 2.0 * absf(patch.detune_cents) / float(patch.detune_voices - 1)
	return f * (pow(2.0, step / 1200.0) - 1.0)

# Seed for one take. Sequential, except for a two-voice unison: there the only
# thing a seed decides is the phase offset between the two voices — which
# harmonics reinforce and which cancel — so the takes are spread evenly across
# the offsets that sound different (0 .. half a cycle; the other half mirrors
# it) instead of landing wherever the dice put them.
static func _take_seed(base_seed: int, variant: int, variants: int, patch: SynthPatch) -> int:
	var first: int = base_seed + variant * 7919
	if patch.detune_voices != 2 or patch.detune_cents == 0.0 or patch.noise_mix >= 1.0:
		return first
	var want: float = 0.5 * (float(variant) + 0.5) / float(variants)
	var rng := RandomNumberGenerator.new()
	for k in 4096:
		# The engine's first two draws after seeding are the unison phases.
		rng.seed = first + k
		var a: float = rng.randf()
		var offset: float = fposmod(rng.randf() - a, 1.0)
		if offset > 0.5:
			offset = 1.0 - offset
		if absf(offset - want) < 0.01:
			return first + k
	return first

# ---------------------------------------------------------------------------
# One take: render, loop
# ---------------------------------------------------------------------------

# Render one note of [param base] and return the pre-clip float signal at
# velocity 1: {buf, rate, pitch, gate, kind, loop_begin, loop_end, fade}.
# loop_end is 0 for a one-shot.
static func _render_take(base: SynthPatch, note: float, gate: float, seed: int, s: Settings) -> Dictionary:
	var has_noise: bool = base.noise_mix > 0.0
	var pure_noise: bool = base.noise_mix >= 1.0
	var split: bool = has_noise and not pure_noise
	var rate: float = s.noise_rate if pure_noise else s.mix_rate
	# Seconds per render block — the live engine's, whatever rate is rendered at
	# (see _render). Events land on block boundaries.
	var block: float = float(SynthEngine._MAX_CHUNK) / s.noise_rate

	var take := {"rate": rate, "pitch": note, "gate": -1.0, "kind": "",
		"loop_begin": 0, "loop_end": 0, "fade": 0}
	var plan: Dictionary = {}
	var tonal: SynthPatch = base
	var seconds: float
	var events: Array = [[0.0, SynthEngine.CMD_NOTE_ON, 0, note, 1.0, 0.0]]
	if base.sustain > 0.0:
		plan = _plan_loop(base, note, rate, s)
		take["pitch"] = plan["pitch"]
		take["kind"] = plan["kind"]
		events[0][3] = plan["pitch"]
		if plan["vibrato_rate"] != base.vibrato_rate:
			tonal = base.duplicate()
			tonal.vibrato_rate = plan["vibrato_rate"]
		seconds = float(plan["start"] + plan["length"]) / rate + block
	else:
		var natural: float = maxf(base.attack, 0.0) + maxf(base.decay, 0.0)
		if s.bake_gates and gate >= 0.0 and gate < natural:
			# Rounded up to a block, and at least one: a track sends its note-off on
			# the first frame at or after the note's end, never before it, and a
			# note-off in the note-on's own block would kill the voice unheard.
			var gate_q: float = maxf(ceilf(gate / block - 1e-6), 1.0) * block
			take["gate"] = gate_q
			events.append([gate_q + 1e-7, SynthEngine.CMD_NOTE_OFF, 0, roundi(note)])
			seconds = gate_q + maxf(base.release, 0.0) + 2.0 * block
		else:
			seconds = natural + 2.0 * block
	var frames: int = int(ceil(seconds * rate))

	var buf := PackedFloat32Array()
	buf.resize(frames)
	var noise_buf := PackedFloat32Array()
	if not pure_noise:
		var t: SynthPatch = tonal
		if has_noise:
			t = tonal.duplicate()
			t.gain = tonal.gain * (1.0 - tonal.noise_mix)
			t.noise_mix = 0.0
		buf = _render(t, events, frames, s.mix_rate, seed, s)
	if has_noise:
		var n: SynthPatch = base.duplicate()
		n.gain = base.gain * base.noise_mix
		n.noise_mix = 1.0
		# Nothing below reaches the output of a pure-noise voice; off, it is
		# cheaper and draws nothing from the RNG ahead of the noise.
		n.detune_voices = 1
		n.fm_index = 0.0
		n.vibrato_depth_cents = 0.0
		n.pitch_decay_semitones = 0.0
		var n_frames: int = int(ceil(seconds * s.noise_rate))
		noise_buf = _render(n, events, n_frames, s.noise_rate, seed ^ 0x5bd1e995, s)
		if split:
			noise_buf = _resample(noise_buf, s.mix_rate / s.noise_rate, frames)

	if not plan.is_empty():
		var begin: int = plan["start"]
		var length: int = plan["length"]
		if not pure_noise and plan["fade"] > 0:
			_crossfade_loop(buf, begin, length, plan["fade"], plan["equal_power"])
		if has_noise and plan["noise_fade"] > 0:
			_crossfade_loop(noise_buf, begin, length, plan["noise_fade"], true)
		take["loop_begin"] = begin
		take["loop_end"] = begin + length
		take["fade"] = maxi(plan["fade"], plan["noise_fade"])
		frames = begin + length

	if pure_noise:
		buf = noise_buf
	elif has_noise:
		for i in mini(buf.size(), noise_buf.size()):
			buf[i] += noise_buf[i]
	buf.resize(frames)
	if take["loop_end"] > 0:
		for j in _LOOP_TAIL:
			buf.append(buf[int(take["loop_begin"]) + j % int(plan["length"])])
	take["buf"] = buf
	return take

# Render [param events] for [param patch] on channel 0 and return the float
# signal (one voice is mono; the left channel is all of it). Whatever the rate,
# the render block lasts as long as the live engine's: that is how often a note
# is started or released and — audibly, on a fast sweep — how often the filter
# cutoff moves.
static func _render(patch: SynthPatch, events: Array, frames: int, rate: float,
		seed: int, s: Settings) -> PackedFloat32Array:
	var synth := SynthEngine.new()
	synth.master_gain = s.master_gain
	synth.loudness_compensation = s.loudness_compensation
	synth.offline_chunk = maxi(roundi(float(SynthEngine._MAX_CHUNK) * rate / s.noise_rate), 1)
	var out: Array = synth.render_offline_raw(events, [patch], frames, rate, seed)
	synth.free()
	return out[0]

# Where and how to loop a held note of [param p]: {kind, start, length (frames),
# fade (frames, oscillator part; 0 = the loop is exact), equal_power,
# noise_fade (frames), pitch (the note to render — retuned so the loop holds
# whole cycles), vibrato_rate (ditto for whole LFO cycles)}.
#
# A steady note of this engine is periodic unless something beats: the wavetable
# is read cyclically (even with inharmonic partials in it), the filter is linear
# and at rest, and FM at ratio a/b repeats every b carrier cycles. So:
#   periodic   n whole cycles in L whole samples, by nudging the pitch to
#              n * rate / L. Exact — no crossfade, nothing to hear.
#   + vibrato  L is whole LFO cycles (LFO rate nudged the same way) and the pitch
#              is nudged so the carrier, whose frequency now wobbles, still
#              completes whole cycles over them. Still exact.
#   beat       unison voices drift against each other; the loop is whole beat
#              cycles, where they are back where they started but for the
#              slight curvature of cents, which a short crossfade absorbs.
#   frozen     the beat cycle is too long to store (seconds, for a bass): a few
#              cycles are looped with a short crossfade, holding the unison
#              voices where they were. The slow movement is gone.
#   crossfade  nothing repeats (sustained noise, FM at an irrational ratio): a
#              long stretch with an equal-power crossfade.
static func _plan_loop(p: SynthPatch, note: float, rate: float, s: Settings) -> Dictionary:
	var f: float = 440.0 * pow(2.0, (note - 69.0) / 12.0)
	var has_tonal: bool = p.noise_mix < 1.0
	var held_noise: bool = p.noise_mix > 0.0 and p.noise_decay <= 0.0

	var settle: float = maxf(p.attack, 0.0) + maxf(p.decay, 0.0)
	if p.filter_type != SynthPatch.FilterType.OFF and p.filter_env_amount != 0.0:
		settle = maxf(settle, maxf(p.filter_attack, 0.0) + maxf(p.filter_decay, 0.0))
	if p.pitch_decay_semitones > 0.0 and p.pitch_decay_time > 0.0:
		settle = maxf(settle, p.pitch_decay_time)
	if p.noise_mix > 0.0 and p.noise_decay > 0.0:
		settle = maxf(settle, p.noise_decay)
	if p.filter_type != SynthPatch.FilterType.OFF:
		# A resonant filter rings on after its cutoff has stopped moving: allow
		# six time constants (-52 dB) at the cutoff it comes to rest on.
		var cutoff: float = clampf(p.filter_cutoff + p.filter_env_amount * p.filter_sustain, 0.0, 1.0)
		var hz: float = minf(20.0 * pow(1000.0, cutoff), rate * 0.45)
		settle += 6.0 * (0.5 + p.filter_resonance * p.filter_resonance * 19.5) / (PI * hz)
	settle += s.settle_seconds

	var plan := {"kind": "crossfade", "start": 0, "length": 0, "fade": 0,
		"equal_power": false, "noise_fade": 0, "pitch": note, "vibrato_rate": p.vibrato_rate}
	var noise_fade: int = roundi(s.noise_fade_seconds * rate)
	if held_noise:
		plan["noise_fade"] = noise_fade

	if not has_tonal:
		plan["length"] = roundi(s.noise_loop_seconds * rate)
	else:
		var has_vibrato: bool = p.vibrato_depth_cents > 0.0 and p.vibrato_rate > 0.0
		var fm_period: int = _fm_period(p.fm_ratio) if p.fm_index > 0.0 else 1
		var inharmonic: bool = fm_period == 0
		var q: int = maxi(fm_period, 1)
		var kind: String = "periodic"
		var target: float = s.min_loop_seconds
		var cycles_up: bool = true  # round the cycle count up (a floor on length)
		if p.detune_voices > 1 and p.detune_cents != 0.0:
			var beat: float = 1.0 / _beat_rate(p, note)
			if beat <= s.max_beat_seconds:
				kind = "beat"
				target = ceilf(target / beat - 1e-6) * beat
				cycles_up = false
			else:
				kind = "frozen"
		if held_noise or inharmonic:
			# Long enough that the repeat of something random is not a pitch.
			target = maxf(target, s.noise_loop_seconds)

		var length: int
		var cycles: float
		if has_vibrato:
			var lfo_cycles: int = maxi(1, int(ceilf(target * p.vibrato_rate - 1e-6)))
			length = roundi(lfo_cycles * rate / p.vibrato_rate)
			plan["vibrato_rate"] = float(lfo_cycles) * rate / float(length)
			# Carrier cycles per loop = f/rate * sum of the pitch factor over the
			# loop's samples, which is the same wherever in the LFO cycle it starts.
			var factor_sum: float = 0.0
			for i in length:
				var lfo: float = sin(TAU * float(lfo_cycles) * float(i) / float(length))
				factor_sum += pow(2.0, lfo * p.vibrato_depth_cents / 1200.0)
			cycles = maxf(roundf(f * factor_sum / rate / float(q)), 1.0) * float(q)
			f = cycles * rate / factor_sum
		else:
			cycles = f * target / float(q)
			cycles = maxf(ceilf(cycles - 1e-6) if cycles_up else roundf(cycles), 1.0) * float(q)
			length = roundi(cycles * rate / f)
			f = cycles * rate / float(length)
		plan["length"] = length
		plan["pitch"] = 69.0 + 12.0 * log(f / 440.0) / log(2.0)
		if inharmonic:
			plan["fade"] = mini(noise_fade, length / 2)
			plan["equal_power"] = true
		elif kind != "periodic":
			plan["fade"] = clampi(roundi(rate / f), roundi(0.005 * rate), length / 2)
		if not held_noise and not inharmonic:
			plan["kind"] = kind

	# The crossfade reads the stretch just before the loop, so that must exist.
	plan["start"] = maxi(int(ceil(settle * rate)), maxi(plan["fade"], plan["noise_fade"]))
	return plan

# Carrier cycles after which FM at [param ratio] repeats (the denominator of the
# ratio), or 0 when it does not within _MAX_FM_PERIOD.
static func _fm_period(ratio: float) -> int:
	for q in range(1, _MAX_FM_PERIOD + 1):
		var x: float = ratio * float(q)
		if absf(x - roundf(x)) < 1e-4:
			return q
	return 0

# Make buf[begin .. begin+length) loop seamlessly by fading its last [param fade]
# frames into the frames that precede [param begin] — so the frame after the loop
# end is, in effect, the loop's first. Linear for signals that line up across the
# seam, equal-power for ones that do not (noise).
static func _crossfade_loop(buf: PackedFloat32Array, begin: int, length: int,
		fade: int, equal_power: bool) -> void:
	var end: int = begin + length
	for i in fade:
		var u: float = (float(i) + 0.5) / float(fade)
		var a: float = cos(u * PI * 0.5) if equal_power else 1.0 - u
		var b: float = sin(u * PI * 0.5) if equal_power else u
		buf[end - fade + i] = buf[end - fade + i] * a + buf[begin - fade + i] * b

# ---------------------------------------------------------------------------
# One sample: velocity, clip, normalise, pack
# ---------------------------------------------------------------------------

# Turn a take into the sample for [param velocity]:
# {stream, gain, peak (pre-clip), clipped_fraction, curve, seam}.
static func _finish_take(take: Dictionary, velocity: float, s: Settings) -> Dictionary:
	var src: PackedFloat32Array = take["buf"]
	var n: int = src.size()
	var looped: bool = take["loop_end"] > 0
	var buf := PackedFloat32Array()
	buf.resize(n)
	var peak: float = 0.0
	var clipped: int = 0
	var energy: float = 0.0
	# The channel player's clip, on this one voice at the level it is played at.
	for i in n:
		var x: float = src[i] * velocity
		var a: float = absf(x)
		if a > peak:
			peak = a
		if x > 1.0:
			x = 1.0
			clipped += 1
		elif x < -1.0:
			x = -1.0
			clipped += 1
		energy += x * x
		buf[i] = x

	# Through a clipper level stops following velocity; measure by how much.
	var curve := PackedFloat32Array()
	if clipped > 0 and energy > 0.0:
		curve.resize(_CURVE_POINTS)
		for k in _CURVE_POINTS:
			var v: float = float(k) / float(_CURVE_POINTS - 1)
			var e: float = 0.0
			for i in n:
				var x: float = clampf(src[i] * v, -1.0, 1.0)
				e += x * x
			curve[k] = sqrt(e / energy)

	# A one-shot ends where its envelope did; drop the silence rendered after it.
	if not looped:
		var last: int = n - 1
		while last > 0 and absf(buf[last]) < 1.0 / 32768.0:
			last -= 1
		n = mini(last + 2, n)
		buf.resize(n)

	var out_peak: float = minf(peak, 1.0)
	var gain: float = s.ceiling / out_peak if out_peak > 0.0 else 1.0
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, roundi(clampf(buf[i] * gain, -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = int(take["rate"])
	wav.data = bytes
	var seam: float = 0.0
	if looped:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = take["loop_begin"]
		wav.loop_end = take["loop_end"]
		# Seam check: the step from the loop's last frame back to its first,
		# against the largest step between neighbours inside the loop.
		var step: float = 0.0
		for i in range(int(take["loop_begin"]) + 1, int(take["loop_end"])):
			step = maxf(step, absf(buf[i] - buf[i - 1]))
		var jump: float = absf(buf[take["loop_begin"]] - buf[int(take["loop_end"]) - 1])
		seam = jump / step if step > 0.0 else 0.0
	return {
		"stream": wav,
		"gain": gain,
		"peak": peak,
		"clipped_fraction": float(clipped) / float(maxi(n, 1)),
		"curve": curve,
		"seam": seam,
	}

static func _peak(buf: PackedFloat32Array) -> float:
	var peak: float = 0.0
	for x in buf:
		var a: float = absf(x)
		if a > peak:
			peak = a
	return peak

# Band-limited resample of [param buf] by [param ratio] (output rate / input
# rate) to [param out_frames] frames: Blackman-windowed sinc, cut off at the
# lower of the two Nyquists. At a whole-number ratio the input samples pass
# through untouched and only the ones in between are interpolated.
static func _resample(buf: PackedFloat32Array, ratio: float, out_frames: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(out_frames)
	var n: int = buf.size()
	var cutoff: float = minf(1.0, ratio)  # relative to the input Nyquist
	var half: float = float(_SINC_HALF) / cutoff
	for o in out_frames:
		var pos: float = float(o) / ratio
		var k0: int = int(ceil(pos - half))
		var k1: int = int(floor(pos + half))
		var acc: float = 0.0
		for k in range(maxi(k0, 0), mini(k1, n - 1) + 1):
			var t: float = pos - float(k)
			var x: float = t * cutoff
			var sinc: float = 1.0 if absf(x) < 1e-9 else sin(PI * x) / (PI * x)
			var w: float = t / half  # -1 .. 1 across the window
			var window: float = 0.42 + 0.5 * cos(PI * w) + 0.08 * cos(TAU * w)
			acc += buf[k] * sinc * window * cutoff
		out[o] = acc
	return out
