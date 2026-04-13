class_name SynthEngine
extends Node

# Polyphonic wavetable synth feeding an AudioStreamGenerator.
#
# Voice rendering is per-sample in GDScript, so cost is roughly:
#   mix_rate * active_voices * (~1 wavetable read + ADSR + lowpass)
# 22050 Hz with up to ~16 voices fits comfortably; raise mix_rate for quality
# at the cost of CPU. Each voice uses a precomputed wavetable from its patch
# (see SynthPatch) so there are no per-sample sin() calls in the hot path.

@export var mix_rate: float = 22050.0
@export var buffer_length: float = 0.05
@export var max_voices: int = 24
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

var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _voices: Array[Voice] = []
var _patches: Array[SynthPatch] = []
var _default_patch: SynthPatch
var _age_counter: int = 0
var _lfo_time: float = 0.0

func _ready() -> void:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = mix_rate
	stream.buffer_length = buffer_length
	_player = AudioStreamPlayer.new()
	_player.stream = stream
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()

	_voices.resize(max_voices)
	for i in max_voices:
		_voices[i] = Voice.new()

	_default_patch = SynthPatch.new()
	_patches.resize(16)
	for i in 16:
		_patches[i] = _default_patch

func set_patch(channel: int, patch: SynthPatch) -> void:
	if channel < 0 or channel >= 16 or patch == null:
		return
	_patches[channel] = patch

func note_on(channel: int, note: int, velocity: float = 1.0) -> void:
	var v := _allocate_voice()
	var patch: SynthPatch = _patches[channel]
	_age_counter += 1
	v.active = true
	v.released = false
	v.channel = channel
	v.note = note
	v.freq = 440.0 * pow(2.0, (note - 69) / 12.0)
	v.velocity = clamp(velocity, 0.0, 1.0)
	v.patch = patch
	v.phase = 0.0
	v.env_state = ENV_ATTACK
	v.env_value = 0.0
	v.lp_state = 0.0
	v.pitch_time = 0.0
	v.age = _age_counter
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
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return
	var dt := 1.0 / mix_rate
	var buf := PackedVector2Array()
	buf.resize(frames)

	for i in frames:
		_lfo_time += dt
		var sample := 0.0
		for v in _voices:
			if v.active:
				sample += _render_voice(v, dt)
		sample *= master_gain
		if sample > 1.0:
			sample = 1.0
		elif sample < -1.0:
			sample = -1.0
		buf[i] = Vector2(sample, sample)

	_playback.push_buffer(buf)

func _render_voice(v: Voice, dt: float) -> float:
	var p: SynthPatch = v.patch

	# --- Envelope -------------------------------------------------------
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

	# --- Oscillator (mono or detuned unison) ----------------------------
	var sample := 0.0
	var dv := p.detune_voices
	if dv <= 1:
		sample = p.sample(v.phase)
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
			sample += p.sample(v.detune_phase[i])
			var ph: float = v.detune_phase[i] + f * dt
			if ph >= 1.0:
				ph -= floor(ph)
			v.detune_phase[i] = ph
		sample *= inv_count

	# --- Noise mix -------------------------------------------------------
	if p.noise_mix > 0.0:
		var noise: float = randf() * 2.0 - 1.0
		if p.noise_mix >= 1.0:
			sample = noise
		else:
			sample = sample * (1.0 - p.noise_mix) + noise * p.noise_mix

	sample *= v.env_value * v.velocity * p.gain

	# --- One-pole lowpass ----------------------------------------------
	if p.lowpass < 1.0:
		v.lp_state += p.lowpass * (sample - v.lp_state)
		sample = v.lp_state

	return sample
