# godot_synth

A wavetable synthesizer, dynamic music system, and runtime SFX bank for Godot 4. Compose your soundtrack with chord progressions instead of audio files. Generate sound effects from math instead of digging through asset packs at 2 AM.

## What's in the box

- **Polyphonic wavetable synth.** Additive harmonics, sine, square, saw, triangle. Or just bring your own one-cycle waveform — the engine doesn't care.
- **Resonant SVF filter** with its own ADSR envelope. The squelchy kind you hear in trance music. Use sparingly.
- **FM operator** for bells, electric pianos, and clangs. Set `fm_index` to 3.0 if you want regrets.
- **Noise generator** with independent decay + LP/HP filters. Snare drums and ocean waves come from the same place, philosophically speaking.
- **Per-channel audio buses** routed through Godot's mixer, so you get reverb / delay / EQ / compression for free via Godot's built-in `AudioEffect` nodes.
- **Dynamic music director.** Define a chord progression once, then write patterns as scale degrees or chord tones. The melody automatically harmonizes with whatever chord is active. Swap progressions at runtime without restarting the song.
- **MIDI file parser** because you might want to import that demo from 1996.
- **A Synth tab in the editor** with a patch designer (sliders for every parameter, a pile of factory presets), a visual pattern editor (piano roll, marquee select, copy/paste, movable playhead) and a track list, all auditioning through one shared live preview. Click around. Make noise.

## Installation

Drop the addon into your project at `addons/godot_synth/`. Or add as a git submodule:

```bash
git submodule add https://github.com/lost-conn/gd-synth.git addons/godot_synth
```

The classes register themselves via `class_name`, so the runtime needs nothing enabled. To get the **Synth** editor tab (below), enable the plugin in Project > Project Settings > Plugins. The `examples/music_test.tscn` scene is F6-able as soon as the addon is in your project.

Nothing in the addon hardcodes its install folder: the code uses relative `preload("./...")` paths and the example scenes reference scripts by UID, so `addons/godot_synth/` and `addons/gd-synth/` both work.

## Quick start: making a noise

```gdscript
var synth := SynthEngine.new()
add_child(synth)

var patch := SynthPatch.make_organ()
synth.set_patch(0, patch)
synth.note_on(0, 60, 0.8)  # MIDI 60 (C4), velocity 0.8

# Later:
synth.note_off(0, 60)
```

You now have an organ. Congratulations.

## Quick start: making music

The recommended setup uses three autoloads — a synth, a director (beat clock + chord progression), and an SFX dispatcher. Wire them in `project.godot`:

```ini
[autoload]
Synth="*res://scenes/audio/synth.tscn"
Music="*res://scenes/audio/music.tscn"
```

Each of those scenes is a single Node with the right script attached.

Then drop a `MusicTrack` somewhere in your scene tree, hand it a `MusicPattern.tres`, and `activate()` it. The track auto-wires to `/root/Music` and `/root/Synth`, plays its pattern in time with the global beat, and resolves note pitches against the current chord.

## Architecture, briefly

Three layers, each owning one job:

| Layer | What it does | Doesn't do |
|---|---|---|
| `SynthEngine` | Pushes audio frames through a buffer pool. Manages voices, channels, buses. | Anything tempo- or music-related. |
| `MusicDirector` | Tracks beats, advances through chord blocks, exposes "what chord/scale is active right now" queries. | Make any sound itself. |
| `MusicTrack` | Reads a pattern, resolves notes against the director, drives a synth channel. | Care which director or synth it talks to (auto-wires). |

This means the synth is happily reusable for SFX even without music playing, the director is queryable from game code (e.g. "fire a particle on every beat"), and tracks can come and go without anyone noticing.

## Key resources

| Class | Saved as | Edit it in |
|---|---|---|
| `SynthPatch` | `.tres` | The Synth tab's Sound view. Or the inspector. Or notepad if you're feeling brave. |
| `MusicPattern` | `.tres` | The Synth tab's Pattern view (piano roll). |
| `PatternNote` | inline sub-resource | Footer of the pattern editor. |
| `MusicBlock` | inline or `.tres` | Inspector. Defines one chord + scale + duration. |
| `MusicData` | `.tres` | Inspector. A list of MusicBlocks plus BPM. |
| `SynthSampleSet` | `.res` | Nowhere — `SynthSampleBaker` makes it. A patch, baked to samples. |

## Editor tools

### The Synth tab

Enable the plugin and a **Synth** tab appears next to 2D / 3D / Script. It is one workspace with three views, switched from the bar at the top:

- **Sound** hosts the patch editor: harmonics, envelope, filter, FM, noise, presets, load/save of `SynthPatch` resources.
- **Pattern** hosts the pattern editor: a piano roll (marquee select, copy/paste, bends, a movable playhead) with a note inspector, load/save of `MusicPattern` resources.
- **Track** lists the `MusicTrack` nodes of a music scene you pick (a `.tscn`): name, type, pattern, patch, channel, octave. Read-only for now.

The bar also has a transport (**Play** / **Stop** / **Loop**), a readout of the previewed `MusicData` (BPM, key, and the progression as chord symbols, with the current block lit while playing), and a chip on the right for sample-bake status.

Double-click a `SynthPatch`, `MusicPattern` or `MusicData` `.tres` in the FileSystem dock and the editor jumps to the Synth tab and opens it in the matching view. (Selecting one of those resources anywhere else, such as clicking a track's `patch` property in the inspector, does the same: that is how Godot treats a main-screen editor.)

**One shared preview.** The tab owns a single `SynthEngine`, `MusicDirector` and preview `MusicTrack`, and never touches a game's `/root/Synth` or `/root/Music` autoloads. Both editors play through them, and the *current patch* is shared: tweak a patch in Sound, switch to Pattern, press Play, and the pattern is heard through that same patch as it is right now. Pick a different patch from the Pattern view and Sound follows. If no `MusicData` is chosen, previews run against a built-in default (120 BPM, C major, one block), so Play always works. Loop off plays once through the progression (or the pattern, if it is longer) and stops. Switching to another editor tab stops playback and idles the engine.

The preview plays dry on the editor's Master bus: a track's `output_bus` and `effects` are ignored in the editor so the preview never adds buses to the editor's own AudioServer.

### `@tool` scripts

The editor tab runs the real engine classes inside the editor, so they are `@tool`: `SynthEngine`, `MusicDirector`, `MusicTrack` and the resources `SynthPatch`, `MusicPattern`, `PatternNote`, `PatternBend`, `MusicBlock`, `MusicData`, plus the editor scripts. A `SynthEngine`, `MusicDirector` or `MusicTrack` that merely sits in a scene you have open in the editor stays inert: no audio, no autoplay, no ticking, no autoload lookup. Only a node whose `editor_preview` is set to `true` before it enters the tree (the tab's own preview nodes) comes alive while `Engine.is_editor_hint()`. `editor_preview` is not exported, so it is never saved into a scene.

### Standalone

- `addons/godot_synth/editor/pattern_editor.tscn` — the pattern editor on its own. F6-able. It builds a private preview on first Play; configure `preview_music_data` and `preview_patch` in the inspector to choose what it plays against (with none, the built-in default).
- `addons/godot_synth/examples/music_test.tscn` — the demo scene. Shows the patch editor, includes a typing-keyboard piano (A-K), and a sample song that toggles with F2.
- `addons/godot_synth/examples/pattern_editor_demo.tscn` — the pattern editor in a bare scene.

## SFX without the music side

If you only want the synth (no chord progression, no patterns, just trigger-a-sound-on-an-event), you can skip the music director entirely. Use `SynthEngine` directly, or build your own thin dispatcher with a pool of `MusicTrack` nodes pre-configured for one-shot patterns. There's a worked example in the parent project this addon was extracted from.

## Baking

Rendering every voice in GDScript is the expensive way to make a sound. Two ways out, both built on `SynthEngine`'s offline renderer (same DSP, no audio thread):

- **`SynthBaker`** flattens a whole song, or one SFX pattern, to a single `AudioStreamWAV`. Costs nothing to play; no longer follows the chord progression, because it is a recording of one.
- **`SynthSampleBaker`** turns a `SynthPatch` into a `SynthSampleSet`: single notes, recorded at the pitches, velocities and lengths your patterns actually play them. `SynthSampler` (below) pitches and mixes those through Godot's mixer while the director and tracks keep sequencing as before. `sample_set.gd` spells out what a sampler has to do; `sample_baker.gd` explains how the notes are recorded (why noise is rendered at the live rate, where loops go, why a decaying note is recorded with its note-off).

```gdscript
var usage := SynthSampleBaker.Usage.new()
SynthSampleBaker.add_pattern_usage(usage, pattern, MusicTrack.TrackType.DRUM, 4, [], 120.0)
var sample_set := SynthSampleBaker.bake(patch, usage)
ResourceSaver.save(sample_set, "res://samples/kick.res")
print(SynthSampleBaker.last_report)   # roots, peak, what clipped, bytes
```

A set remembers the patch it came from: `sample_set.is_stale(patch)` says when to bake again.

### Playing the sets: `SynthSampler`

`SynthSampler` extends `SynthEngine` and plays those sets through Godot's mixer, one `AudioStreamPlayer` per voice: no render thread, no per-sample GDScript. Its call surface is the engine's (`set_patch`, `note_on`, `note_off`, `bend_to`, `all_notes_off`, channel buses, `master_gain`, `max_voices`, `set_enabled`), so `MusicTrack`, `MidiPlayer` and game code keep working against `SynthEngine`-typed variables.

To switch a game over:

1. Bake a set for every patch it plays, into one directory, named after the patch file (`patches/kick.tres` plays `kick.res`). `SynthSampleBaker` does the baking; a project-side tool that walks its songs, SFX table and scenes for the notes each patch is really played at is worth writing — see `tools/bake_samples_job.gd` in the parent project. Re-bake when a patch changes: a stale set warns once and plays anyway (`allow_stale`).
2. Put `synth_sampler.gd` on the node where `synth_engine.gd` was (an autoload scene, say) and point `samples_dir` at the sets. Nothing that drives the synth changes.
3. A patch with no file of its own (made in code, or embedded in a scene) has no set to look up: hand it one with `set_patch_sample_set(patch, set)`. A patch with no set leaves its channel silent, with one warning.

What it cannot reproduce (pan, the filter envelope's release, exact timing) is listed at the top of `synth_sampler.gd` and `sample_set.gd`. `mix_rate` and `buffer_length` mean nothing to it; `configure()` applies only `max_voices`.

To compare it with the live engine by ear, set `live = true` on the node before it enters the tree (from a subclass's `_init()`, say, keyed off a command-line flag). Every method then hands to `SynthEngine`'s and the node is the plain live synth.

## Channel allocation

The synth has 16 channels. Each holds one `SynthPatch` and gets its own `AudioServer` bus (named `Ch{N}`) routed to wherever you want via `output_bus`. Two tracks sharing a channel will share its patch and effect chain — fine for some uses, surprising for others. There's a 24-voice global pool; voice stealing is "oldest wins."

## Performance notes

GDScript per-sample audio rendering is CPU-bound but runs comfortably for ~16 active voices at 22050 Hz on a modern desktop. Bump `mix_rate` to 44100 if your saws sound aliased. Drop `max_voices` if your Steam Deck is angry. Enabling FM, the resonant filter, or many noise voices increases per-voice cost — most patches use only a subset.

## License

MIT. Do whatever you want, attribution appreciated, no warranty if the FM index of 8.0 makes your speakers leave.

## Credits

Built incrementally for [3dimenshift](https://github.com/lost-conn) and extracted as a standalone addon. Patches contributed willingly. Bug reports contributed reluctantly.
