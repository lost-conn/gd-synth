class_name SynthSampleSet
extends Resource

# The baked form of one SynthPatch: a handful of single-note recordings a sampler
# plays back through Godot's mixer instead of rendering the patch voice-by-voice.
# Made by SynthSampleBaker; never edited by hand.
#
# Each sample is ONE voice of the patch exactly as the live engine would have put
# it on its channel player — oscillator, unison detune, FM, noise, filter and
# filter envelope, pitch envelope, amp envelope, the note's equal-loudness gain,
# SynthEngine.master_gain and the per-channel ±1 clip are all in the audio. A
# voice is mono in the engine (pan is two gains on the way out), so samples are
# mono, 16-bit.
#
# Samples are parallel arrays indexed by sample: streams[i], root_pitches[i], ...
# A root may have several samples: `variants` takes of the same note (different
# random unison phases / noise, see below) and, rarely, a second velocity layer.
#
# ---------------------------------------------------------------------------
# What a sampler does with it (the contract)
# ---------------------------------------------------------------------------
# note_on(channel, note, velocity, pan)
#   1. Humanize first, as the engine does: detune `note` by up to
#      ±pitch_randomize_cents and scale `velocity` by a random factor in
#      [1 - velocity_randomize, 1]. Both were zeroed for the bake.
#   2. i = find_sample(note, velocity, variant). Rotate or randomize `variant`
#      per note_on: live, every note of a detuned or noisy patch comes out
#      different, and the variants are what is left of that.
#   3. Play streams[i] at get_pitch_scale(i, note) and get_volume(i, note,
#      velocity) (linear — convert with linear_to_db). The stream carries its own
#      mix rate and loop points, so nothing else is needed to start it.
#   4. Pan: a centred voice is the sample at unity on both sides, which is how
#      Godot plays a mono stream. Off-centre the engine uses
#      l = 1 - max(pan, 0), r = 1 + min(pan, 0) — the far side fades, the near
#      side stays put. Not equal-power.
#
# note_off(channel, note), `elapsed` seconds after its note_on
#   • needs_release(i, elapsed, pitch_scale) false: do nothing. The sample was
#     recorded with its own note-off (gates[i]) and its release is already in the
#     audio, or it has simply finished.
#   • true: ramp the voice's volume linearly IN AMPLITUDE (not in dB) to zero over
#     `release` seconds, then stop it. That is the engine's release exactly when
#     the note has reached its sustain; a note released mid-decay comes out a
#     little shorter than live, because the sample keeps decaying under the ramp.
#     The filter envelope's own release is not reproduced.
#   The engine releases the oldest unreleased voice of that (channel, rounded
#   note); all_notes_off() cuts every voice dead with no release at all.
#
# Sustained notes (sustains == true) loop inside the stream: play it and it holds
# until released. Their gates[i] is always < 0. (The stream runs a few frames
# past loop_end, repeating the loop's start: Godot plays the frame at loop_end
# before wrapping.)
#
# Pitch bend / glide: the engine glides exponentially (a straight line in
# semitones) from the voice's current pitch to the target over the glide time.
# The sampler does that on the voice's pitch_scale, target = get_pitch_scale(i,
# target_note). There is no other way to bend a playing sample, and it is not
# free: everything baked into the audio speeds up with it — decay and filter
# sweep shorten, vibrato and unison beating speed up — where the live voice only
# changes pitch. The level stays what it was at note_on (the engine does not
# re-evaluate equal-loudness during a glide either). max_bend_up / max_bend_down
# are the largest bends the baker saw in the game's patterns.
#
# Voice stealing is the sampler's to do: the engine has one pool of max_voices
# across all channels and takes the oldest voice when it is full.
#
# What does NOT survive baking, for whoever compares the two by ear:
#   • The channel clip is per voice here. Live it acts on the channel's summed
#     voices, so overlapping notes of a patch that drives the clip (see
#     preclip_peaks) intermodulate live and do not here; and a patch whose single
#     notes stay under ±1 but whose chords do not clips live and not here.
#   • Vibrato always starts at phase 0 (live it runs off a clock shared by all
#     voices), and a sample played off its root has its vibrato rate, envelope
#     times and unison beating scaled by the pitch ratio.
#   • Noise is not pitched live, so a sample with noise in it is only right at
#     its root. pitch_tracks is false for a pure-noise patch: play it at
#     pitch_scale 1 whatever the note.

# --- Provenance --------------------------------------------------------------

## [member SynthPatch.patch_name] of the source patch.
@export var patch_name: String = ""

## Resource path of the source patch at bake time (informational; a patch built
## in code has none).
@export var source_patch: String = ""

## [method fingerprint_patch] of the source patch at bake time. A set whose
## fingerprint no longer matches its patch is stale — see [method is_stale].
@export var patch_fingerprint: String = ""

## Fingerprint of everything that went into the bake: the patch, the notes /
## velocities / gates it was baked for, and the baker's settings and version.
## Differs from a fresh [method SynthSampleBaker.bake_fingerprint] when a re-bake
## would produce different samples even though the patch itself did not change
## (a pattern gained a note, a tempo changed).
@export var bake_fingerprint: String = ""

## [constant SynthSampleBaker.VERSION] that produced this set.
@export var baker_version: int = 0

# --- How it was rendered -----------------------------------------------------

## Sample rate (Hz) the oscillator part was rendered at. Individual streams carry
## their own rate: a pure-noise patch is stored at [member noise_rate].
@export var mix_rate: int = 44100

## Rate (Hz) the noise part was rendered at — the live engine's rate, because its
## noise generator and one-pole noise filters are per output sample and sound
## different at any other.
@export var noise_rate: int = 22050

## [member SynthEngine.master_gain] baked into the samples.
@export var master_gain: float = 0.6

## [member SynthEngine.loudness_compensation] baked into the samples.
## [method get_volume] uses it to correct a note played off its root.
@export var loudness_compensation: float = 1.0

# --- What the sampler cannot recover from the audio ---------------------------

## Amp envelope of the source patch, seconds / level. [member release] is the
## length of the note-off ramp; the rest is for a sampler that wants to know
## where in the envelope a voice is.
@export var attack: float = 0.0
@export var decay: float = 0.0
@export var sustain: float = 0.0
@export var release: float = 0.0

## True when a held note keeps sounding (the patch's sustain level is above
## zero): every sample then has a loop and plays until released. False for
## percussive / decaying patches, whose samples are one-shots.
@export var sustains: bool = false

## False for a pure-noise patch, which sounds the same at every pitch: play its
## samples at pitch_scale 1. [method get_pitch_scale] already does.
@export var pitch_tracks: bool = true

## Humanization the sampler applies per note_on (zeroed for the bake). See
## [member SynthPatch.pitch_randomize_cents], [member SynthPatch.velocity_randomize].
@export var pitch_randomize_cents: float = 0.0
@export var velocity_randomize: float = 0.0

## Most takes any root has. More than 1 when the patch is random from note to
## note — detuned unison voices start at random phases, noise is noise. A root
## may have fewer; [method find_sample] wraps to the ones it has.
@export var variants: int = 1

## Largest pitch bend the game's patterns ask of this patch, in semitones up and
## down from the note that was struck. 0 = the patch is never bent.
@export var max_bend_up: float = 0.0
@export var max_bend_down: float = 0.0

## How the sustain loop was built: "" (one-shots), "periodic" (whole cycles, the
## root retuned so they fit the loop exactly), "beat" (whole unison beat cycles),
## "frozen" (a few cycles with the unison beat held where it was), "crossfade"
## (a long crossfaded stretch: sustained noise, inharmonic FM). Roots can differ
## — a unison beat is short high up and long low down — and then this lists each
## kind used, "/"-separated.
@export var loop_kind: String = ""

# --- Samples (parallel arrays) -------------------------------------------------

## The recordings. Mono, 16-bit, each normalised on its own (see [member gains]).
@export var streams: Array[AudioStreamWAV] = []

## Pitch each sample sounds at when played at pitch_scale 1, as a fractional MIDI
## note. Not quite a whole note for a looped sample — it is retuned so a whole
## number of cycles fits its loop, by a fraction of a cent as a rule and a few
## cents when the loop also has to hold whole vibrato cycles — so compute pitch
## ratios from this, not from the rounded note.
@export var root_pitches: PackedFloat32Array = PackedFloat32Array()

## Which take of its root this is, 0 .. [member variants] - 1.
@export var variant_ids: PackedInt32Array = PackedInt32Array()

## Velocity the sample was rendered at. Velocity only scales level in the engine
## — it never touches the filter or FM — so one layer serves every velocity,
## except through the channel clip: a sample that clipped ([member preclip_peaks]
## above 1) has that much drive in it whatever volume it is played at.
@export var velocities: PackedFloat32Array = PackedFloat32Array()

## Linear gain applied to each sample when it was normalised into the 16-bit
## range. Divide by it to get the engine's level back ([method get_volume] does).
@export var gains: PackedFloat32Array = PackedFloat32Array()

## Seconds after note-on at which the sample's own note-off was rendered, or a
## negative number when it was rendered held (to its natural end, or looping).
## A sample with a gate has its release in the audio — see [method needs_release].
@export var gates: PackedFloat32Array = PackedFloat32Array()

## Peak of each sample before the channel clip, at [member velocities]. Above 1
## the live channel player was clipping this note and so does the sample.
@export var preclip_peaks: PackedFloat32Array = PackedFloat32Array()

## Fraction of each sample's frames that sit on the clip.
@export var clipped_fractions: PackedFloat32Array = PackedFloat32Array()

## For samples that clipped: output level relative to the stored sample at
## velocity k / (size - 1), k = 0 .. size - 1, measured through the clip. Through
## a clipper level stops following velocity, and this is by how much. Empty for a
## sample that did not clip (level is then proportional to velocity).
@export var velocity_curves: Array[PackedFloat32Array] = []

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

## Number of samples.
func size() -> int:
	return streams.size()

## Index of the sample to play for [param note] at [param velocity], or -1 if the
## set is empty. Picks the nearest root; among that root's velocity layers the
## quietest one rendered at or above [param velocity]; among its takes number
## [param variant], wrapped to how many there are.
func find_sample(note: float, velocity: float = 1.0, variant: int = 0) -> int:
	var n: int = streams.size()
	if n == 0:
		return -1
	var best_root: float = root_pitches[0]
	var best_dist: float = absf(root_pitches[0] - note)
	for i in range(1, n):
		var d: float = absf(root_pitches[i] - note)
		if d < best_dist - 1e-4:
			best_dist = d
			best_root = root_pitches[i]
	# Velocity layer: lowest rendered velocity that still covers the request,
	# else the highest there is.
	var layer: float = -1.0
	var top: float = 0.0
	for i in n:
		if absf(root_pitches[i] - best_root) > 1e-4:
			continue
		var lv: float = velocities[i]
		top = maxf(top, lv)
		if lv >= velocity - 1e-4 and (layer < 0.0 or lv < layer):
			layer = lv
	if layer < 0.0:
		layer = top
	var takes: PackedInt32Array = PackedInt32Array()
	for i in n:
		if absf(root_pitches[i] - best_root) <= 1e-4 and absf(velocities[i] - layer) <= 1e-4:
			takes.append(i)
	return takes[posmod(variant, takes.size())]

## pitch_scale that makes sample [param i] sound at [param note] (fractional
## MIDI). Always 1 when the patch does not track pitch.
func get_pitch_scale(i: int, note: float) -> float:
	if not pitch_tracks:
		return 1.0
	return pow(2.0, (note - root_pitches[i]) / 12.0)

## Linear volume that makes sample [param i] as loud as the engine would play
## [param note] at [param velocity]: undoes the normalisation, follows velocity
## (through the clip, if the sample clipped) and corrects the equal-loudness gain
## when [param note] is not the sample's root.
func get_volume(i: int, note: float, velocity: float) -> float:
	var level: float
	var curve: PackedFloat32Array = velocity_curves[i] if i < velocity_curves.size() else PackedFloat32Array()
	var vel: float = clampf(velocity, 0.0, 1.0)
	if curve.size() >= 2:
		var x: float = vel * float(curve.size() - 1)
		var k: int = mini(int(x), curve.size() - 2)
		level = lerpf(curve[k], curve[k + 1], x - float(k))
	else:
		level = vel / maxf(velocities[i], 1e-6)
	var comp: float = _loudness(note) / _loudness(root_pitches[i])
	return level * comp / maxf(gains[i], 1e-9)

## Whether a note_off arriving [param elapsed] seconds after its note_on has to
## be turned into a release ramp. False once a gated sample has passed its own
## baked note-off (allowing [param slack] seconds for the caller's frame timing)
## or any one-shot has run out. [param pitch_scale] is what the voice is playing
## at — a pitched-up sample reaches its gate sooner.
func needs_release(i: int, elapsed: float, pitch_scale: float = 1.0, slack: float = 0.03) -> bool:
	var position: float = elapsed * maxf(pitch_scale, 1e-6)
	if gates[i] >= 0.0:
		return position < gates[i] - slack
	if sustains:
		return true
	return position < streams[i].get_length()

## Distinct roots in the set, ascending.
func get_roots() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for r in root_pitches:
		var seen: bool = false
		for o in out:
			if absf(o - r) < 1e-4:
				seen = true
				break
		if not seen:
			out.append(r)
	out.sort()
	return out

## Bytes of sample data across all streams.
func get_data_bytes() -> int:
	var total: int = 0
	for s in streams:
		total += s.data.size()
	return total

# The engine's equal-loudness gain for a note (see SynthEngine._apply_note_on).
func _loudness(note: float) -> float:
	if loudness_compensation <= 0.0:
		return 1.0
	var freq: float = 440.0 * pow(2.0, (note - 69.0) / 12.0)
	return lerpf(1.0, clampf(sqrt(440.0 / freq), 0.25, 3.0), loudness_compensation)

# ---------------------------------------------------------------------------
# Staleness
# ---------------------------------------------------------------------------

## True when [param patch] no longer matches the patch this set was baked from.
func is_stale(patch: SynthPatch) -> bool:
	return patch == null or patch_fingerprint != fingerprint_patch(patch)

## Hash of every stored property of [param patch] that shapes its sound (all of
## them but the name). Two patches with the same fingerprint bake to the same set.
static func fingerprint_patch(patch: SynthPatch) -> String:
	if patch == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for prop in patch.get_property_list():
		var usage: int = prop["usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 or usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pname: String = prop["name"]
		if pname == "patch_name":
			continue
		parts.append("%s=%s" % [pname, var_to_str(patch.get(pname))])
	parts.sort()
	return "\n".join(parts).sha256_text()
