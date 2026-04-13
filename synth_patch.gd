class_name SynthPatch
extends Resource

# Designer-facing instrument definition. Builds a single-cycle wavetable from
# additive harmonics on init so the engine's per-sample work is just a table
# lookup instead of N sin() calls.

enum Waveform { ADDITIVE, SINE, SQUARE, SAW, TRIANGLE }

@export var patch_name: String = "Patch"

@export var waveform: Waveform = Waveform.ADDITIVE:
	set(value):
		waveform = value
		if _table.size() == TABLE_SIZE:
			rebuild()

# Amplitudes per harmonic. Index 0 = fundamental, index 1 = 2nd partial, etc.
# Setter rebuilds the wavetable so live edits and loaded resources both
# refresh automatically.
@export var harmonics: PackedFloat32Array = PackedFloat32Array([1.0, 0.5, 0.25, 0.125]):
	set(value):
		harmonics = value
		if _table.size() == TABLE_SIZE:
			rebuild()

# Optional inharmonic ratios per partial. Zero or missing entries fall back
# to integer multiples (1, 2, 3, ...). Use this for bell-like timbres.
@export var harmonic_ratios: PackedFloat32Array = PackedFloat32Array():
	set(value):
		harmonic_ratios = value
		if _table.size() == TABLE_SIZE:
			rebuild()

# ADSR in seconds; sustain is 0..1 level.
@export var attack: float = 0.01
@export var decay: float = 0.10
@export_range(0.0, 1.0) var sustain: float = 0.7
@export var release: float = 0.20

# One-pole lowpass cutoff coefficient. 1.0 disables the filter.
@export_range(0.0, 1.0) var lowpass: float = 1.0

@export var gain: float = 0.5

# Stack N detuned voices per note for chorus / unison fatness.
@export_range(1, 4) var detune_voices: int = 1
@export var detune_cents: float = 6.0

# LFO pitch modulation.
@export var vibrato_rate: float = 0.0      # Hz
@export var vibrato_depth_cents: float = 0.0

# Noise mix: 0 = pure oscillator, 1 = pure white noise. Essential for
# snare, hi-hat, and cymbal patches.
@export_range(0.0, 1.0) var noise_mix: float = 0.0

# Pitch envelope: pitch starts this many semitones above the MIDI note
# and decays to the note frequency over pitch_decay_time seconds.
# Used for kick drums and tom-like sounds.
@export var pitch_decay_semitones: float = 0.0
@export var pitch_decay_time: float = 0.0

const TABLE_SIZE: int = 2048

var _table: PackedFloat32Array

func _init() -> void:
	rebuild()

func rebuild() -> void:
	_table = PackedFloat32Array()
	_table.resize(TABLE_SIZE)
	var peak := 0.0
	for i in TABLE_SIZE:
		var phase := float(i) / float(TABLE_SIZE)
		var s := 0.0
		match waveform:
			Waveform.SINE:
				s = sin(phase * TAU)
			Waveform.SQUARE:
				s = 1.0 if phase < 0.5 else -1.0
			Waveform.SAW:
				s = phase * 2.0 - 1.0
			Waveform.TRIANGLE:
				s = 4.0 * absf(phase - 0.5) - 1.0
			_: # ADDITIVE
				for h in harmonics.size():
					var amp: float = harmonics[h]
					if amp == 0.0:
						continue
					var ratio: float = float(h + 1)
					if h < harmonic_ratios.size() and harmonic_ratios[h] > 0.0:
						ratio = harmonic_ratios[h]
					s += sin(phase * TAU * ratio) * amp
		_table[i] = s
		var a := absf(s)
		if a > peak:
			peak = a
	if peak > 0.0:
		var inv := 1.0 / peak
		for i in TABLE_SIZE:
			_table[i] *= inv

func sample(phase: float) -> float:
	# Linear-interpolated wavetable read. Phase is 0..1.
	var x: float = phase * float(TABLE_SIZE)
	var ix: int = int(x)
	var i0: int = ix % TABLE_SIZE
	var i1: int = (i0 + 1) % TABLE_SIZE
	var frac: float = x - float(ix)
	return _table[i0] + (_table[i1] - _table[i0]) * frac

# --- Factory helpers for common timbres ---------------------------------

static func make_organ() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Organ"
	p.harmonics = PackedFloat32Array([1.0, 0.8, 0.6, 0.5, 0.4, 0.3, 0.2, 0.15])
	p.attack = 0.02
	p.decay = 0.05
	p.sustain = 0.9
	p.release = 0.15
	p.gain = 0.35
	p.rebuild()
	return p

static func make_clarinet() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Clarinet"
	# Odd harmonics only — square-ish but softened.
	p.harmonics = PackedFloat32Array([1.0, 0.0, 0.7, 0.0, 0.4, 0.0, 0.25, 0.0, 0.15])
	p.attack = 0.04
	p.decay = 0.1
	p.sustain = 0.85
	p.release = 0.2
	p.lowpass = 0.6
	p.gain = 0.4
	p.rebuild()
	return p

static func make_bell() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Bell"
	p.harmonics = PackedFloat32Array([1.0, 0.6, 0.4, 0.25, 0.18])
	# Inharmonic partials — classic FM-bell ratios.
	p.harmonic_ratios = PackedFloat32Array([1.0, 2.76, 5.40, 8.93, 13.34])
	p.attack = 0.001
	p.decay = 1.5
	p.sustain = 0.0
	p.release = 0.8
	p.gain = 0.45
	p.rebuild()
	return p

static func make_pad() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Pad"
	p.harmonics = PackedFloat32Array([1.0, 0.4, 0.5, 0.2, 0.3, 0.15, 0.2, 0.1])
	p.attack = 0.6
	p.decay = 0.4
	p.sustain = 0.8
	p.release = 1.2
	p.lowpass = 0.4
	p.detune_voices = 3
	p.detune_cents = 8.0
	p.vibrato_rate = 4.5
	p.vibrato_depth_cents = 6.0
	p.gain = 0.3
	p.rebuild()
	return p

static func make_bass() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Bass"
	p.harmonics = PackedFloat32Array([1.0, 0.5, 0.33, 0.25, 0.2, 0.16, 0.14, 0.12])
	p.attack = 0.005
	p.decay = 0.2
	p.sustain = 0.6
	p.release = 0.1
	p.lowpass = 0.35
	p.gain = 0.5
	p.rebuild()
	return p

# --- Drum presets -----------------------------------------------------------

static func make_kick() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Kick"
	p.waveform = Waveform.SINE
	p.attack = 0.001
	p.decay = 0.25
	p.sustain = 0.0
	p.release = 0.05
	p.pitch_decay_semitones = 48.0
	p.pitch_decay_time = 0.08
	p.gain = 0.6
	p.rebuild()
	return p

static func make_snare() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Snare"
	p.waveform = Waveform.TRIANGLE
	p.noise_mix = 0.7
	p.attack = 0.001
	p.decay = 0.15
	p.sustain = 0.0
	p.release = 0.05
	p.pitch_decay_semitones = 24.0
	p.pitch_decay_time = 0.04
	p.lowpass = 0.5
	p.gain = 0.5
	p.rebuild()
	return p

static func make_hihat() -> SynthPatch:
	var p := SynthPatch.new()
	p.patch_name = "Hi-Hat"
	p.waveform = Waveform.SINE
	p.noise_mix = 1.0
	p.attack = 0.001
	p.decay = 0.06
	p.sustain = 0.0
	p.release = 0.03
	p.lowpass = 0.7
	p.gain = 0.35
	p.rebuild()
	return p
