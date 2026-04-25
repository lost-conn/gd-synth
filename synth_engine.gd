class_name SynthEngine
extends Node

# Polyphonic wavetable synth feeding an AudioStreamGenerator.
#
# Voice rendering is per-sample in GDScript, so cost is roughly:
#   mix_rate * active_voices * (~1 wavetable read + ADSR + lowpass)
# 22050 Hz with up to ~16 voices fits comfortably; raise mix_rate for quality
# at the cost of CPU. Each voice uses a precomputed wavetable from its patch
# (see SynthPatch) so there are no per-sample sin() calls in the hot path.

## Audio sample rate (Hz). 22050 is plenty for game music and costs half the
## CPU of 44100. Higher rates reduce aliasing on bright/saw timbres.
## Cannot be changed after [method _ready].
@export var mix_rate: float = 22050.0

## AudioStreamGenerator buffer length in seconds. Shorter = lower latency but
## higher risk of underruns if a frame stalls. 0.05 is a good default.
@export var buffer_length: float = 0.05

## Voice pool size. When all voices are active, [method note_on] steals the
## oldest voice. Raise for dense polyphony (chords + arpeggios + drums);
## lower to cap CPU on slower machines.
@export var max_voices: int = 24

## Final output level applied after summing all voices. Use for fade in/out
## via tween. Voices are clipped to [-1, 1] after this multiplication.
@export_range(0.0, 1.0) var master_gain: float = 0.6

const ENV_ATTACK := 0
const ENV_DECAY := 1
const ENV_SUSTAIN := 2
const ENV_RELEASE := 3

class Voice:
	var active: bool = false
	var released: bool = false
	var channel: int = 0
	var note: int = 0
	var freq: float = 440.0
	var velocity: float = 1.0
	var patch: SynthPatch
	var phase: float = 0.0
	var detune_phase: PackedFloat32Array = PackedFloat32Array()
	var env_state: int = 0
	var env_value: float = 0.0
	var release_start: float = 1.0
	var lp_state: float = 0.0
	var pitch_time: float = 0.0
	var age: int = 0
	# FM modulator state
	var mod_phase: float = 0.0
	# Filter envelope (ADSR mirror)
	var fenv_state: int = 0
	var fenv_value: float = 0.0
	var fenv_release_start: float = 0.0
	# State-variable filter state (trapezoidal integrator values)
	var svf_ic1: float = 0.0
	var svf_ic2: float = 0.0
	# Per-frame cached SVF coefficients
	var svf_a1: float = 0.0
	var svf_a2: float = 0.0
	var svf_a3: float = 0.0
	var svf_k: float = 2.0
	# Noise state
	var noise_env: float = 1.0
	var noise_lp_state: float = 0.0
	var noise_hp_state: float = 0.0
	# Stereo pan (-1 = full left, 0 = center, +1 = full right)
	var pan: float = 0.0

# One AudioStreamPlayer per channel (0..15), each routable to its own
# audio bus so users can attach Godot's built-in effects (reverb, delay,
# EQ, distortion, compressor, etc.) via the editor's Audio dock.
var _channel_players: Array[AudioStreamPlayer] = []
var _channel_playbacks: Array[AudioStreamGeneratorPlayback] = []
# Name of the auto-created AudioServer bus per channel (empty if none).
# Managed by ensure_channel_bus / release_channel_bus. Cleaned up on
# _exit_tree.
var _channel_buses: Array[StringName] = []
var _voices: Array[Voice] = []
var _patches: Array[SynthPatch] = []
var _default_patch: SynthPatch
var _age_counter: int = 0
var _lfo_time: float = 0.0

# Flat mixdown buffer: index = channel * frames + sample_index.
# Stored as a member to avoid aliasing (PackedArrays stored in a containing
# Array trigger copy-on-write on subscript mutation; direct member access
# stays at refcount=1 so writes are in-place.
var _mixdown: PackedVector2Array = PackedVector2Array()
var _push_buf: PackedVector2Array = PackedVector2Array()

const CHANNEL_COUNT := 16

func _ready() -> void:
	_channel_players.resize(CHANNEL_COUNT)
	_channel_playbacks.resize(CHANNEL_COUNT)
	_channel_buses.resize(CHANNEL_COUNT)
	for ch in CHANNEL_COUNT:
		var stream := AudioStreamGenerator.new()
		stream.mix_rate = mix_rate
		stream.buffer_length = buffer_length
		var player := AudioStreamPlayer.new()
		player.name = "Ch%dPlayer" % ch
		player.stream = stream
		player.bus = &"Master"
		add_child(player)
		player.play()
		_channel_players[ch] = player
		_channel_playbacks[ch] = player.get_stream_playback()
		_channel_buses[ch] = &""

	_voices.resize(max_voices)
	for i in max_voices:
		_voices[i] = Voice.new()

	_default_patch = SynthPatch.new()
	_patches.resize(CHANNEL_COUNT)
	for i in CHANNEL_COUNT:
		_patches[i] = _default_patch

## Route a channel's output to a named audio bus. Users can create buses
## in Godot's Audio dock and attach AudioEffect* nodes (reverb, delay,
## EQ, chorus, distortion, etc.) — those effects then process this
## channel's output before it reaches the master.
func set_channel_bus(channel: int, bus: StringName) -> void:
	if channel < 0 or channel >= CHANNEL_COUNT:
		return
	var p := _channel_players[channel]
	if p != null:
		p.bus = bus

func get_channel_bus(channel: int) -> StringName:
	if channel < 0 or channel >= CHANNEL_COUNT:
		return &"Master"
	var p := _channel_players[channel]
	return p.bus if p != null else &"Master"

## Ensure an auto-bus exists for [param channel], has exactly the given
## [param effects] in order, and sends to [param send_target]. Routes
## the channel's output to this bus. Subsequent calls for the same
## channel replace the effect chain (old effects removed, new ones
## added). Effects are installed by reference — editing an AudioEffect
## resource at runtime affects the live audio.
func ensure_channel_bus(channel: int, effects: Array, send_target: StringName = &"Master") -> StringName:
	if channel < 0 or channel >= CHANNEL_COUNT:
		return &"Master"
	var name: StringName = _channel_buses[channel]
	var idx: int = -1
	if name != &"":
		idx = AudioServer.get_bus_index(name)
	if idx == -1:
		var base := StringName("Ch%d" % channel)
		name = _unique_bus_name(base)
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, name)
		_channel_buses[channel] = name
	# Clear + install fresh effect chain.
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	for eff in effects:
		if eff != null:
			AudioServer.add_bus_effect(idx, eff)
	AudioServer.set_bus_send(idx, send_target)
	set_channel_bus(channel, name)
	return name

## Remove the auto-bus for [param channel] and reset the channel's
## output to Master. Called internally on _exit_tree; game code rarely
## needs this directly.
func release_channel_bus(channel: int) -> void:
	if channel < 0 or channel >= CHANNEL_COUNT:
		return
	var name: StringName = _channel_buses[channel]
	if name == &"":
		return
	var idx: int = AudioServer.get_bus_index(name)
	if idx != -1:
		AudioServer.remove_bus(idx)
	_channel_buses[channel] = &""
	set_channel_bus(channel, &"Master")

func _unique_bus_name(base: StringName) -> StringName:
	if AudioServer.get_bus_index(base) == -1:
		return base
	var i: int = 2
	while AudioServer.get_bus_index(StringName("%s_%d" % [base, i])) != -1:
		i += 1
	return StringName("%s_%d" % [base, i])

func _exit_tree() -> void:
	for ch in CHANNEL_COUNT:
		release_channel_bus(ch)

func set_patch(channel: int, patch: SynthPatch) -> void:
	if channel < 0 or channel >= 16 or patch == null:
		return
	_patches[channel] = patch

func note_on(channel: int, note: int, velocity: float = 1.0, pan: float = 0.0) -> void:
	var v := _allocate_voice()
	var patch: SynthPatch = _patches[channel]
	_age_counter += 1
	v.active = true
	v.released = false
	v.channel = channel
	v.note = note
	var effective_freq: float = 440.0 * pow(2.0, (note - 69) / 12.0)
	if patch.pitch_randomize_cents > 0.0:
		var cents: float = (randf() * 2.0 - 1.0) * patch.pitch_randomize_cents
		effective_freq *= pow(2.0, cents / 1200.0)
	v.freq = effective_freq
	var eff_vel: float = clamp(velocity, 0.0, 1.0)
	if patch.velocity_randomize > 0.0:
		eff_vel *= lerpf(1.0 - patch.velocity_randomize, 1.0, randf())
	v.velocity = eff_vel
	v.pan = clampf(pan, -1.0, 1.0)
	v.patch = patch
	v.phase = 0.0
	v.env_state = ENV_ATTACK
	v.env_value = 0.0
	v.lp_state = 0.0
	v.pitch_time = 0.0
	v.age = _age_counter
	v.mod_phase = 0.0
	v.fenv_state = ENV_ATTACK
	v.fenv_value = 0.0
	v.fenv_release_start = 0.0
	v.svf_ic1 = 0.0
	v.svf_ic2 = 0.0
	v.noise_env = 1.0
	v.noise_lp_state = 0.0
	v.noise_hp_state = 0.0
	var dv := patch.detune_voices
	if dv > 1:
		v.detune_phase = PackedFloat32Array()
		v.detune_phase.resize(dv)
		for i in dv:
			v.detune_phase[i] = randf()

func note_off(channel: int, note: int) -> void:
	for v in _voices:
		if v.active and not v.released and v.channel == channel and v.note == note:
			v.released = true
			v.env_state = ENV_RELEASE
			v.release_start = v.env_value
			v.fenv_state = ENV_RELEASE
			v.fenv_release_start = v.fenv_value
			return

func all_notes_off() -> void:
	for v in _voices:
		v.active = false
		v.released = false

func _allocate_voice() -> Voice:
	var oldest: Voice = _voices[0]
	var oldest_age := 0x7fffffff
	for v in _voices:
		if not v.active:
			return v
		if v.age < oldest_age:
			oldest_age = v.age
			oldest = v
	return oldest

func _process(_delta: float) -> void:
	if _channel_playbacks.is_empty() or _channel_playbacks[0] == null:
		return
	# Use channel 0's playback to determine how many frames to fill; all
	# channels share the same mix_rate + buffer_length so they stay in sync.
	var frames := _channel_playbacks[0].get_frames_available()
	if frames <= 0:
		return
	var dt := 1.0 / mix_rate

	# Precompute expensive SVF coefficients once per buffer (tan + pow).
	for v in _voices:
		if v.active and v.patch != null and v.patch.filter_type != SynthPatch.FilterType.OFF:
			_update_svf_coefs(v, v.patch)

	# Resize + zero the flat mixdown buffer.
	var total_frames := CHANNEL_COUNT * frames
	if _mixdown.size() != total_frames:
		_mixdown.resize(total_frames)
	_mixdown.fill(Vector2.ZERO)

	# Render all voices, accumulate to their channel's slice of the buffer.
	for i in frames:
		_lfo_time += dt
		for v in _voices:
			if v.active:
				var s := _render_voice(v, dt)
				var l: float = s * (1.0 - maxf(v.pan, 0.0))
				var r: float = s * (1.0 + minf(v.pan, 0.0))
				var idx: int = v.channel * frames + i
				var cur: Vector2 = _mixdown[idx]
				_mixdown[idx] = Vector2(cur.x + l, cur.y + r)

	# Per-channel: apply master gain, clip, push to that channel's player.
	if _push_buf.size() != frames:
		_push_buf.resize(frames)
	for ch in CHANNEL_COUNT:
		var playback: AudioStreamGeneratorPlayback = _channel_playbacks[ch]
		if playback == null:
			continue
		var base := ch * frames
		for i in frames:
			var s: Vector2 = _mixdown[base + i] * master_gain
			if s.x > 1.0: s.x = 1.0
			elif s.x < -1.0: s.x = -1.0
			if s.y > 1.0: s.y = 1.0
			elif s.y < -1.0: s.y = -1.0
			_push_buf[i] = s
		playback.push_buffer(_push_buf)

func _update_svf_coefs(v: Voice, p: SynthPatch) -> void:
	# Effective cutoff: base + envelope modulation, clamped to 0..1.
	var cutoff_norm: float = clampf(p.filter_cutoff + p.filter_env_amount * v.fenv_value, 0.0, 1.0)
	# Log-map 0..1 to ~20 Hz..~mix_rate/2.2.
	var freq: float = 20.0 * pow(1000.0, cutoff_norm)
	freq = minf(freq, mix_rate * 0.45)
	var g: float = tan(PI * freq / mix_rate)
	# Quadratic ramp on resonance for a more natural feel.
	var q_val: float = 0.5 + p.filter_resonance * p.filter_resonance * 19.5
	var k: float = 1.0 / q_val
	v.svf_a1 = 1.0 / (1.0 + g * (g + k))
	v.svf_a2 = g * v.svf_a1
	v.svf_a3 = g * v.svf_a2
	v.svf_k = k

func _render_voice(v: Voice, dt: float) -> float:
	var p: SynthPatch = v.patch

	# --- Amp envelope ---------------------------------------------------
	match v.env_state:
		ENV_ATTACK:
			if p.attack <= 0.0:
				v.env_value = 1.0
				v.env_state = ENV_DECAY
			else:
				v.env_value += dt / p.attack
				if v.env_value >= 1.0:
					v.env_value = 1.0
					v.env_state = ENV_DECAY
		ENV_DECAY:
			if p.decay <= 0.0:
				v.env_value = p.sustain
				v.env_state = ENV_SUSTAIN
			else:
				v.env_value -= dt * (1.0 - p.sustain) / p.decay
				if v.env_value <= p.sustain:
					v.env_value = p.sustain
					v.env_state = ENV_SUSTAIN
		ENV_SUSTAIN:
			pass
		ENV_RELEASE:
			if p.release <= 0.0:
				v.env_value = 0.0
			else:
				v.env_value -= dt * v.release_start / p.release
			if v.env_value <= 0.0:
				v.active = false
				return 0.0

	# --- Filter envelope (only when filter is enabled) ------------------
	if p.filter_type != SynthPatch.FilterType.OFF:
		match v.fenv_state:
			ENV_ATTACK:
				if p.filter_attack <= 0.0:
					v.fenv_value = 1.0
					v.fenv_state = ENV_DECAY
				else:
					v.fenv_value += dt / p.filter_attack
					if v.fenv_value >= 1.0:
						v.fenv_value = 1.0
						v.fenv_state = ENV_DECAY
			ENV_DECAY:
				if p.filter_decay <= 0.0:
					v.fenv_value = p.filter_sustain
					v.fenv_state = ENV_SUSTAIN
				else:
					v.fenv_value -= dt * (1.0 - p.filter_sustain) / p.filter_decay
					if v.fenv_value <= p.filter_sustain:
						v.fenv_value = p.filter_sustain
						v.fenv_state = ENV_SUSTAIN
			ENV_SUSTAIN:
				pass
			ENV_RELEASE:
				if p.filter_release <= 0.0:
					v.fenv_value = 0.0
				else:
					v.fenv_value -= dt * v.fenv_release_start / p.filter_release
				if v.fenv_value < 0.0:
					v.fenv_value = 0.0

	# --- Pitch + vibrato + pitch envelope --------------------------------
	var freq := v.freq
	if p.vibrato_depth_cents > 0.0 and p.vibrato_rate > 0.0:
		var lfo := sin(_lfo_time * TAU * p.vibrato_rate)
		freq *= pow(2.0, (lfo * p.vibrato_depth_cents) / 1200.0)
	if p.pitch_decay_semitones > 0.0 and p.pitch_decay_time > 0.0:
		var t: float = clampf(v.pitch_time / p.pitch_decay_time, 0.0, 1.0)
		var semis: float = p.pitch_decay_semitones * (1.0 - t)
		freq *= pow(2.0, semis / 12.0)
		v.pitch_time += dt

	# --- FM modulator (single operator, sine modulator) -----------------
	var fm_offset: float = 0.0
	if p.fm_index > 0.0:
		var mod_freq: float = freq * p.fm_ratio
		v.mod_phase += mod_freq * dt
		if v.mod_phase >= 1.0:
			v.mod_phase -= floor(v.mod_phase)
		fm_offset = sin(v.mod_phase * TAU) * p.fm_index

	# --- Oscillator (mono or detuned unison) ----------------------------
	var sample := 0.0
	var dv := p.detune_voices
	if dv <= 1:
		sample = p.sample(fposmod(v.phase + fm_offset, 1.0))
		v.phase += freq * dt
		if v.phase >= 1.0:
			v.phase -= floor(v.phase)
	else:
		var inv_count: float = 1.0 / float(dv)
		for i in dv:
			var t: float = 0.5
			if dv > 1:
				t = float(i) / float(dv - 1)
			var cents: float = lerpf(-p.detune_cents, p.detune_cents, t)
			var f: float = freq * pow(2.0, cents / 1200.0)
			sample += p.sample(fposmod(v.detune_phase[i] + fm_offset, 1.0))
			var ph: float = v.detune_phase[i] + f * dt
			if ph >= 1.0:
				ph -= floor(ph)
			v.detune_phase[i] = ph
		sample *= inv_count

	# --- Noise (filtered, with independent decay envelope) --------------
	if p.noise_mix > 0.0:
		var noise: float = randf() * 2.0 - 1.0
		if p.noise_lowpass < 1.0:
			v.noise_lp_state += p.noise_lowpass * (noise - v.noise_lp_state)
			noise = v.noise_lp_state
		if p.noise_highpass > 0.0:
			v.noise_hp_state += p.noise_highpass * (noise - v.noise_hp_state)
			noise -= v.noise_hp_state
		if p.noise_decay > 0.0 and v.noise_env > 0.0:
			v.noise_env -= dt / p.noise_decay
			if v.noise_env < 0.0:
				v.noise_env = 0.0
		if p.noise_mix >= 1.0:
			sample = noise * v.noise_env
		else:
			sample = sample * (1.0 - p.noise_mix) + noise * p.noise_mix * v.noise_env

	# --- Resonant SVF filter --------------------------------------------
	if p.filter_type != SynthPatch.FilterType.OFF:
		var v3: float = sample - v.svf_ic2
		var v1: float = v.svf_a1 * v.svf_ic1 + v.svf_a2 * v3
		var v2: float = v.svf_ic2 + v.svf_a2 * v.svf_ic1 + v.svf_a3 * v3
		v.svf_ic1 = 2.0 * v1 - v.svf_ic1
		v.svf_ic2 = 2.0 * v2 - v.svf_ic2
		match p.filter_type:
			SynthPatch.FilterType.LOWPASS:
				sample = v2
			SynthPatch.FilterType.HIGHPASS:
				sample = sample - v.svf_k * v1 - v2
			SynthPatch.FilterType.BANDPASS:
				sample = v1

	sample *= v.env_value * v.velocity * p.gain

	# --- Legacy one-pole lowpass (post-amp) -----------------------------
	if p.lowpass < 1.0:
		v.lp_state += p.lowpass * (sample - v.lp_state)
		sample = v.lp_state

	return sample
