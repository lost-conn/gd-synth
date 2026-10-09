@tool
extends EditorScript

# Editor bake tool: renders every one-shot SFX to an AudioStreamWAV .res that the
# game plays back on the LOW quality tier instead of the live synth. Loop SFX are
# skipped (they need runtime bpm modulation). CHORD/MELODY SFX resolve against
# the song's tonic block.
#
# Run from the editor: open this file, then File > Run (Ctrl+Shift+X).
# Re-run whenever an SFX patch / pattern changes.

const SfxBank = preload("res://scripts/audio/sfx_bank.gd")
const SynthBaker = preload("res://addons/godot_synth/baker.gd")

const MIX_RATE := SynthBaker.DEFAULT_MIX_RATE

func _run() -> void:
	var bank := SfxBank.new()
	bank.bake_all(MIX_RATE)  # self-loads its resources when called on a bare instance
	bank.free()
