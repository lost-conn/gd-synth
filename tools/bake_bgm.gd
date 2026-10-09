@tool
extends EditorScript

# Editor bake tool: renders a whole-song scene (MusicDataPlayer + MusicTracks)
# to a seamless looping AudioStreamWAV resource the game can play back on
# low-end hardware instead of running the live synth.
#
# Run from the editor: open this file, then File > Run (Ctrl+Shift+X).
# Re-run whenever the patches / patterns / progression change.
#
# Output is an AudioStreamWAV .res (loads directly, no import step). At 44100 Hz
# stereo 16-bit a ~45 s loop is ~8 MB; if that's too heavy for web, re-save the
# .wav through Godot's importer with Ogg/ADPCM compression, or drop MIX_RATE.

const SynthBaker = preload("res://addons/godot_synth/baker.gd")

# --- Config -----------------------------------------------------------------
const SONG_SCENE := "res://scenes/audio/main_music.tscn"
const OUT_PATH := "res://resources/audio/baked/bgm/main.res"
const MIX_RATE := SynthBaker.DEFAULT_MIX_RATE
# LIMIT_PEAK never clips but bakes a hot mix quieter (the printed gain says how
# much). CHANNEL_CLIP keeps the live per-channel clip; CLIP is the old bake.
const GAIN_MODE := SynthEngine.OfflineGain.LIMIT_PEAK

func _run() -> void:
	var scene: PackedScene = load(SONG_SCENE)
	if scene == null:
		push_error("[bake_bgm] Could not load %s" % SONG_SCENE)
		return
	var root := scene.instantiate()
	var song := SynthBaker.collect_song(root)
	if song.data == null:
		push_error("[bake_bgm] No MusicData found in %s" % SONG_SCENE)
		root.free()
		return

	var wav: AudioStreamWAV = SynthBaker.bake_song(
		song.data, song.tracks, 0.0, MIX_RATE, 1.0, 1234, GAIN_MODE)
	root.free()
	if wav == null:
		push_error("[bake_bgm] Bake produced no audio.")
		return

	var dir := OUT_PATH.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var err := ResourceSaver.save(wav, OUT_PATH)
	if err != OK:
		push_error("[bake_bgm] Save failed (%d) -> %s" % [err, OUT_PATH])
		return
	var seconds := float(wav.data.size() / 4) / MIX_RATE
	print("[bake_bgm] Saved %.1fs loop -> %s (%d KB)" % [
		seconds, OUT_PATH, wav.data.size() / 1024])
	var st: Dictionary = SynthBaker.last_stats
	print("[bake_bgm] %d Hz, pre-clip peak %.3f, %d of %d samples clipped, gain %.3f" % [
		int(MIX_RATE), st.peak, st.clipped_samples, st.samples, st.gain])
