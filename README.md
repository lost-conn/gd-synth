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
| `PatternNote` | inline sub-resource | The Pattern view's inspector. |
| `PatternChain` | `.tres` | Inspector (its steps). Opens read-only in the Pattern view. |
| `SynthKit` | inline or `.tres` | The Track view's inspector (a Drum track's pieces). |
| `MusicBlock` | inline or `.tres` | Inspector. Defines one chord + scale + duration. |
| `MusicData` | `.tres` | Inspector. A list of MusicBlocks plus BPM. |
| `MusicSong` | `.tres` | Inspector. A running order of `MusicSection`s (each with `MusicSectionSlot`s) plus BPM. |
| `SynthSampleSet` | `.res` | Nowhere — `SynthSampleBaker` makes it. A patch, baked to samples. |

## Chaining patterns: `PatternChain`

A `PatternChain` is a `MusicPattern` made of other patterns, so it goes anywhere a pattern does: `MusicTrack.pattern`, `swap_pattern()`, the bake. Its `steps` (`PatternChainStep` resources) play one after another and the chain loops at the end of the last one:

```gdscript
var verse := PatternChain.new()
verse.add_step(riff, 2)               # riff twice
verse.add_step(riff, 1, 1, 0.7)       # then once, an octave up, at 70% velocity
verse.add_step(fill)
track.pattern = verse
```

Each step has a `pattern` (which may itself be a chain), `repeats` (at least 1), `octave_shift` and `velocity_scale`. The chain plays exactly as one long pattern would: every note is copied with its beat moved to its place in the chain, its octave (and its bends' octaves) shifted and its velocity scaled and clamped to 0..1, then resolved against the director's current chord / scale like any other note. The source patterns are never changed. A chain's length is the sum of `length_beats * repeats` over its steps. A step that would contain the chain it sits in (a cycle) is skipped with a warning.

`notes` and `length_beats` are derived on a chain, so they are hidden and not saved. **Read what a pattern plays through `get_play_notes()` and `get_play_length()`**, which every `MusicPattern` has (a plain pattern returns `notes` and `length_beats`). The flattened result is cached; a change to the steps, or to the length or note count of a step's pattern, rebuilds it, and in the editor so does any edit to a note. A game that edits a source note's fields in code after the chain has played calls `invalidate()` on the chain.

In the Synth tab a chain opens read-only in the Pattern view (the roll shows the flattened notes) and is edited in the Track view: each step is a clip on its track's lane, and the track's inspector lists the steps (see **Track** below).

## Drum kits: `SynthKit`

A drum track can play a whole beat from **one pattern** instead of one track and pattern per drum. Give a `DRUM` `MusicTrack` a `kit` (a `SynthKit`, whose `pieces` are `SynthKitPiece` resources) and draw the beat in one roll: each row is a drum, and a song section swaps one drums pattern, not three.

```gdscript
var kit := SynthKit.new()
kit.pieces.append(SynthKitPiece.create("Kick", 36, kick_patch))
kit.pieces.append(SynthKitPiece.create("Snare", 38, snare_patch, -1, 0.9, 0.1))   # gain 0.9, pan +0.1
kit.pieces.append(SynthKitPiece.create("Hat", 42, hat_patch, 42, 0.7, -0.2))
drums.kit = kit
drums.synth_channel = 4      # the kit takes channels 4, 5 and 6
```

A piece has a `note` (the pattern row, a MIDI note number, that triggers it), a `patch`, a `pitch` (the MIDI note the patch is played at; -1 plays it at `note`), a `gain` (scales velocity, clamped to 0..1 afterwards) and a `pan` (added to the track's pan, clamped to -1..1). Pitch matters for a patch whose sound follows the note, such as a tom: put the rows where you want them in the roll and the pitch where the patch sounds right. A pattern row that no piece owns is silent; if two pieces share a note the first plays it.

**Channels.** Piece *i* plays on channel `synth_channel + i`, so a kit occupies `synth_channel .. synth_channel + pieces - 1`. Each piece channel gets the track's `output_bus` and `effects`, so give the kit's tracks a shared submix bus if you want one compressor on the drums. If the range runs past channel 15 the track warns and the pieces beyond it are silent; the Track view also warns when a kit's channels overlap another track's. Removing or moving a piece changes the channels of the ones after it. `MusicTrack.patch` is ignored while the kit has pieces (an empty kit counts as no kit, and only a `DRUM` track plays one), and `swap_pattern()` works as before; `swap_kit()` changes the kit.

**Baking.** Sample sets are per patch, so the bake follows the kit: `SynthSampleBaker.add_track_usage_routed()` (and `add_kit_pattern_usage()` for a free-running pattern) hands each piece's notes to the usage of that piece's patch, at the piece's pitch with its gain applied, and `SynthBaker` renders a kit track to the same events the live track would play. `SynthSampleBaker.add_track_usage()` takes one usage and so adds nothing for a kit track. A project's bake tool that reads `track.patch` itself must use `TrackInfo.kit` the same way (the host's `bake_samples_job.gd` shows how). Plain tracks bake exactly as before.

**In the editor.** Select a Drum track in the Track view: the inspector has a **Kit** slot and, once the track has a kit, its pieces, each with a name, note, patch (with Open in Sound), pitch, gain and pan, plus add, remove and move; the channels the kit occupies are shown, and overlaps are flagged on the lane and in the inspector. Every edit is one undo step in the scene. **Make kit** gives a Drum track an inline kit with a piece for each note its pattern plays (named from General MIDI), each using the track's current patch, so the track sounds as before; then give the pieces their own patches. In the Pattern view the rows of a kit's pieces carry their names and are always shown, even when empty, and clicking a row's label or a note auditions it through that piece's patch, pitch, gain and pan. Playing a pattern, or the song in the Track view, plays the kit.

**Moving kick / snare / hi-hat tracks into a kit.** The editor does not convert them for you (nothing rewrites your data behind your back). By hand:

1. On one of the drum tracks, press **Make kit**, or add a `SynthKit` by hand.
2. Give each piece the patch of one of the old tracks and the note its pattern used (the row its notes sit on; a pattern that used 36 for the kick gives a piece with note 36).
3. Merge the patterns into one: open the first drum pattern in the Pattern view, then copy the notes of each other pattern (select them, Ctrl+C) and paste them into it (Ctrl+V). Notes keep their rows, so the kick stays on its row and the snare on its. Make the pattern lengths agree first.
4. Put the merged pattern on the kit track, then delete the old tracks, or leave them in the scene with `autoplay` off while you compare.
5. Check the kit's channel range against the other tracks (the Track view warns on overlap), then re-bake: the sample sets are named after the patches, which did not change.

## Sections and songs: `MusicSection`, `MusicSong`

MusicTracks are the instruments; a song says what they play when. A `MusicSong` is a running order of sections, and a `MusicDataPlayer` whose `song` is set plays it instead of its `music_data` (a scene with only `music_data` behaves exactly as before).

```gdscript
var verse := MusicSection.create("verse", verse_chords, 2)          # its own progression, twice
verse.add_slot(&"Lead", MusicSectionSlot.Mode.PLAY, verse_riff)
verse.add_slot(&"Drums", MusicSectionSlot.Mode.PLAY, groove)
var chorus := MusicSection.create("chorus")                        # the song's progression
chorus.add_slot(&"Lead", MusicSectionSlot.Mode.PLAY, hook)
chorus.add_slot(&"Pad", MusicSectionSlot.Mode.SILENT)
var song := MusicSong.new()
song.bpm = 112.0
song.progression = main_chords
song.add_entry(intro).add_entry(verse).add_entry(chorus, 2).add_entry(verse).add_entry(chorus)
song.loop_entry = 1                                                # after the end, back to the first verse
$MainMusic.song = song
```

**The resources.** A `MusicSection` has a `name`, an optional `progression` (a `MusicData`; null uses the song's `progression`), `repeats`, and `slots`. Its length is the progression's beats × `repeats`, so it always ends on a progression boundary; a section with no progression at all has no length and is skipped. A `MusicSong` has the `bpm`, `beats_per_bar` (for `NEXT_BAR` and the editor), the default `progression`, `entries` (`MusicSongEntry`: a section and how many times in a row it plays), `loop_entry`, and `also_bake`. **Tempo comes from the song only:** the bpm of a section's MusicData is ignored. Helpers for tools: `get_length_beats()`, `entry_start(i)`, `entry_at_beat(beat)` (entry, section, repeat and start beat of any beat on the timeline; past the end it folds into the loop), `section_by_name()`, `get_reachable_sections()`.

**Slots.** A slot names a MusicTrack (its node name) and says what it does when the section starts:

- `PLAY` plays the slot's `pattern` (null: the track's own `pattern` from the scene) from its beat 0 on the section's first beat. It restarts there even when the track was already playing the same pattern, so a chain starts at step 1. An inactive track is activated.
- `SILENT` stops the track; its sounding notes are released.
- `KEEP` leaves the track alone: it carries on with whatever it was playing, or stays silent, without restarting.
- **A track the section does not list behaves as `KEEP`.**

Each repeat of an entry is a new start of its section (PLAY slots restart, `section_changed` fires); a section's own `repeats` are not, they only make it longer. Tracks are looked up among the player's descendants, then among the tracks wired to the director (`MusicDirector.get_tracks()`).

**Timing.** The director keeps one beat clock (while the song plays from the top, its beat is the song's timeline beat; after a loop it keeps counting). Section starts are sums of section lengths, never accumulated frame time, so nothing drifts however long the song runs. At a boundary the player swaps the director's progression (`MusicDirector.set_data_at`), so a note on a section's first beat already resolves against its first block; notes due just before the boundary inside the same frame are played first against the old harmony (`MusicTrack.flush_to`). Tracks the song drives start exactly on the beat, whatever their `swap_mode` / `sync_to_director`. Swing applies as usual.

**The loop point.** After the last entry the song continues at `loop_entry` (`song_looped`, then `section_changed`). KEEP tracks carry on into it from wherever they were.

**Controlling it** (for game code, and for the editor's section preview):

- `play()` starts the song at its first entry; `stop()` stops it and gives the tracks back the pattern and active state they had before the song.
- `play_from_section(index_or_name)` starts at an entry, with every track set as a first pass through the song would have it there (its last PLAY or SILENT before that point, else its own pattern as if it had played from beat 0). `seek(beat)` does the same for any beat of the timeline, and a `MusicDirector.seek()` while a song plays goes through it.
- `set_loop_section(index_or_name)` plays one section again and again from the next boundary (each pass restarts its PLAY slots); `set_loop_section(-1)` resumes the song order at the next boundary, with the entry after the looped one.
- `queue_section(name_or_section, mode)` plays any section once, including one only listed in `also_bake`, taking over at `NEXT_SECTION`, `NEXT_BAR`, `NEXT_BLOCK` (the next chord change) or `NEXT_BEAT`. It plays its full length, and then **the song continues with the entry after the one it interrupted** (that entry's remaining repeats are dropped). A set loop section still wins after it.
- Signals: `section_changed(section, entry_index)` (entry -1 for a queued or looped section no entry plays) and `song_looped`. Getters: `get_current_section()`, `get_current_entry()`, `get_section_start_beat()`, `get_section_length()`.

One song player drives a director at a time. While it does, use its API rather than `MusicDirector.swap_data()`; `swap()` hands the director back to plain `music_data` playback.

**Baking.** `SynthBaker.collect_song()` returns the player's `song` alongside `data`, and its `TrackInfo`s carry the track names. `SynthSampleBaker.add_song_usage_routed()` collects every section the song can reach plus `also_bake` (sections only the game queues: list them there, or they are not baked): a PLAY slot's pattern over that section's progression with the track's type, octave and kit routing at the song's bpm; for a KEEP or unlisted track, its own pattern and every pattern a PLAY slot gives it anywhere, resolved against every block of the section (conservative: it only costs bake size); nothing for SILENT. `SynthBaker.bake_music_song()` renders the song from the top through one pass of the entries as a WAV that plays the intro once and loops from `loop_entry` (queued sections are not in it; a KEEP track whose pattern is elsewhere at the end than at the loop entry jumps there). The host's `bake_samples_job.gd` and `tools/bake_bgm.gd` take the song path when the player has a song.

**In the editor.** The Synth tab's Track view arranges a song by section (see **Track** below): a strip of one chip per entry above the progression, each section's own chords end to end, lanes that draw what each track does in each section, and a song panel to edit the entries, the loop point, the selected section and its slots, and to preview it. A scene with only `music_data` shows a **Convert to song** button instead, which makes a one-section song that plays exactly what the scene plays now.

## Editor tools

### The Synth tab

Enable the plugin and a **Synth** tab appears next to 2D / 3D / Script. It is one workspace with three views, switched from the bar at the top:

- **Sound** is a patch rack: a browser of every `SynthPatch` in the project plus the factory presets, one card per module (oscillator with a harmonics editor, amp envelope, filter, FM and modulation, pitch drop, noise) with small live pictures, and an audition keyboard (click, or A-K while the view has focus) that plays either the live engine or the patch's baked `SynthSampleSet`. Edits go through the editor's undo history. The bake chip says whether the baked set is up to date. The **Bake** button next to it runs your project's own bake tool (see below); the tab cannot re-bake a patch itself, since a set does not record the notes the game plays.
- **Pattern** is a piano roll for a `MusicPattern`. Rows follow the track type (chord tones, scale degrees, or General MIDI drum names; a drum kit's pieces name their own rows) and grow to hold every note; Ctrl+wheel zooms time, Shift or Alt+wheel zooms rows, the wheel scrolls. Click to draw, drag to move or resize, Ctrl-, Shift- or Alt-drag on empty space to marquee select (Shift adds to the selection), arrow keys nudge (Shift+Up/Down an octave), B adds a pitch bend you can then drag by its tip and start. A velocity lane under the roll paints velocities, and the inspector on the right edits every selected note at once. Notes sound as you draw them, and Space plays or stops. The pattern's track type is saved with it (`MusicPattern.editor_track_type`, an editor hint; `MusicTrack.track_type` still decides in the game) and is worked out from the `MusicTrack` that plays the pattern when unset. When the type is set and a `MusicTrack` plays the pattern as another one, the header and the inspector warn, and a Match pattern button sets that track to the pattern's type (one undo step, in a scene that is open in the editor); the Track view flags the same mismatch on the track's lane and in its inspector. The header shows the patch that `MusicTrack` pairs with the pattern and offers it in one click; the other tracks of that scene are drawn faintly behind the roll. Every edit goes through the editor's undo history.
- **Track** is the song arranger for a music scene you pick (a `.tscn`). Across the top, the progression: one chip per `MusicBlock`, as wide as the block is long. Click one to change its chord root, chord quality, scale and length, or to add, move and remove blocks (edits go to the `MusicData` with undo; its header Save writes the file). Below, one lane per `MusicTrack` with its name, type, mute and solo, and its pattern as a clip that repeats at the pattern's length across the timeline (two trips through the progression, or the longest pattern, whichever is longer), each with a tiny note picture. A track that plays a `PatternChain` shows one clip per step and per repeat of the step (repeats and later loops dimmed), labelled with the step's pattern and `+1 oct` / `×0.8` badges; click a step's clip to select it in the inspector. Double-click a clip (a step's clip opens that step's pattern) to edit its pattern in Pattern, with the scene as the song context and the track's patch loaded. The inspector on the right edits the selected track: type, pattern, patch (with Open in Sound), channel, base octave, pan, swap mode, output bus; effects are listed read-only. For a chain it also lists the steps, each with its pattern, repeats, octave shift and velocity scale, and adds, removes, moves and duplicates them; **Make chain** wraps a track's pattern in a one-step chain (inline in the scene), **Use pattern** unwraps a one-step chain, and **Save chain as...** writes the chain to a `.tres` the track then plays. Each of these is one undo step. A type mismatch is flagged when the chain or any of its steps' patterns is marked with a type other than the track's, and Match pattern uses the chain's mark, or the first step's if the chain is Auto. For a Drum track it also shows the track's drum kit (see **Drum kits** above): the Kit slot, **Make kit**, and the pieces with their name, note, patch, pitch, gain and pan (add, remove, move; one undo step each), with the channels the kit occupies and a warning on overlap. **Play** here plays every track together, each on its own channel with its own patch, mute and solo honoured; the playhead runs across the lanes and you click the ruler to move it. A scene whose `MusicDataPlayer` has a `MusicSong` is a **song** in this view, described in the next paragraph; with only a `music_data` it is as described here, plus **Convert to song**. Tracks are edited through the scene, never by writing a `.tscn` from here: with the music scene open in the editor the view holds its live nodes and every change is an undo action on them (the scene tab shows as modified, Ctrl+S saves it); with it closed the view is read-only and offers **Open scene to edit**. Add track / Remove track work the same way. A chip in the header counts the patches that need a re-bake. The scene you pick also lends the preview its `MusicData`, and is the song context the Pattern view draws its other tracks from.

  **A song in the Track view.** The timeline is the song's, one pass of the entries end to end, and its ruler counts bars from the start of each section. Above the progression, the **section strip** has one chip per repeat of every entry, as wide as the section is long and named after it; a section keeps its colour wherever it appears, the loop entry carries a marker (with a line back from the end of the song), and clicking a chip selects its entry. The progression lane shows each section's own chords, the song's for a section without any; dimmed chips are repeats. A lane draws, per section, what its track does there: a PLAY slot draws its pattern or chain restarted at the section start, SILENT is hatched, and KEEP (a slot saying so, or none) draws the pattern it carries on with dimmed and labelled "keep" ("off" when nothing was playing). The **song panel** under the lanes edits, each as one undo step in the scene's history: the entries (**Add section** inserts a new empty section after the selected entry, **Add existing** reuses a section the song has, **Duplicate** adds an unshared copy to write a variation, **Remove**, **<** and **>** to reorder, and how many times the entry plays), **Loop from here** (`loop_entry`), the song's beats per bar and `also_bake` list, and **Save song as...** (writes the song to a `.tres` and makes the player play that file, like Save chain as). For the selected section: its name, its repeats, an **Own progression** toggle (on creates a copy of the progression it plays to edit with the block drawer, off goes back to the song's) and one row per `MusicTrack` of the scene with a Play / Silent / Keep drop-down and, for Play, the pattern or chain and **Open in Pattern**. The block drawer edits the selected section's progression (the song's, shared by every section without its own, otherwise), and the BPM field edits `MusicSong.bpm`. **Play from section** plays the song from the start of the selected section and **Loop section** repeats it; both run the real `MusicDataPlayer` over the preview, so what you hear follows the same section rules the game does. Everything is read-only while the scene is not open in the editor.

The bar also has a transport (**Play** / **Stop** / **Loop**), a readout of the previewed `MusicData` (BPM, key, and the progression as chord symbols, with the current block lit while playing), and, on the right, a **Bake** button and a chip for sample-bake status.

Double-click a `SynthPatch`, `MusicPattern` or `MusicData` `.tres` in the FileSystem dock and the editor jumps to the Synth tab and opens it in the matching view. (Selecting one of those resources anywhere else, such as clicking a track's `patch` property in the inspector, does the same: that is how Godot treats a main-screen editor.)

**One shared preview.** The tab owns a single `SynthEngine`, `MusicDirector` and preview `MusicTrack`, and never touches a game's `/root/Synth` or `/root/Music` autoloads. Both editors play through them, and the *current patch* is shared: tweak a patch in Sound, switch to Pattern, press Play, and the pattern is heard through that same patch as it is right now. Pick a different patch from the Pattern view and Sound follows. If no `MusicData` is chosen, previews run against a built-in default (120 BPM, C major, one block), so Play always works. Loop off plays once through the progression (or the pattern, if it is longer) and stops. Switching to another editor tab stops playback and idles the engine.

The preview plays dry on the editor's Master bus: a track's `output_bus` and `effects` are ignored in the editor so the preview never adds buses to the editor's own AudioServer. The whole-song preview starts every lane at once on the timeline (a track's `swap_mode` and `sync_to_director` are not honoured), and its swing is the preview director's, not part of the song.

### `@tool` scripts

The editor tab runs the real engine classes inside the editor, so they are `@tool`: `SynthEngine`, `MusicDirector`, `MusicTrack` and the resources `SynthPatch`, `MusicPattern`, `PatternNote`, `PatternBend`, `MusicBlock`, `MusicData`, plus the editor scripts. A `SynthEngine`, `MusicDirector` or `MusicTrack` that merely sits in a scene you have open in the editor stays inert: no audio, no autoplay, no ticking, no autoload lookup. Only a node whose `editor_preview` is set to `true` before it enters the tree (the tab's own preview nodes) comes alive while `Engine.is_editor_hint()`. `editor_preview` is not exported, so it is never saved into a scene.

### Standalone

- `addons/godot_synth/editor/pattern_editor.tscn` — the pattern editor on its own. F6-able. It builds a private preview on first Play; configure `preview_music_data` and `preview_patch` in the inspector to choose what it plays against (with none, the built-in default).
- `addons/godot_synth/examples/music_test.tscn` — the demo scene. Shows the patch editor, includes a typing-keyboard piano (A-K), and a sample song that toggles with F2.
- `addons/godot_synth/examples/pattern_editor_demo.tscn` — the pattern editor in a bare scene.

## Tests

`addons/godot_synth/tests/` holds the headless tests: a fast smoke for the older features (chains, drum kits, a two-section song, the Track view over plain, chain, kit and song scenes, custom chord intervals, the roll's marquee) and `test_song_view.gd` for the song timeline (strip, progression lane, lane regions, every section, entry and song edit with undo, the preview against the real `MusicDataPlayer`, Convert to song, Save song as). Run them all from the project folder:

```bash
godot --headless --path <project> -s res://addons/godot_synth/tests/run_all.gd
godot --headless --path <project> -s res://addons/godot_synth/tests/run_all.gd -- song_view   # only files whose name contains this
```

It prints one line per file and the failed checks, and exits non-zero if any failed. The tests use in-memory resources only; the save tests write under `user://` and delete what they wrote. They stand in for the editor with an `UndoRedo` shim (the calls `EditorUndoRedoManager` takes), a Track view that is handed its scene instead of looking up the open scenes, and an engine that records note-ons, so they run without the editor, a display or audio. New test files go in the folder, extend `tests/test_util.gd`, define `run(tree)`, and are listed in `run_all.gd`.

## SFX without the music side

If you only want the synth (no chord progression, no patterns, just trigger-a-sound-on-an-event), you can skip the music director entirely. Use `SynthEngine` directly, or build your own thin dispatcher with a pool of `MusicTrack` nodes pre-configured for one-shot patterns. There's a worked example in the parent project this addon was extracted from.

## Baking

Rendering every voice in GDScript is the expensive way to make a sound. Two ways out, both built on `SynthEngine`'s offline renderer (same DSP, no audio thread):

- **`SynthBaker`** flattens a whole song (a `MusicData` progression, or a `MusicSong` with `bake_music_song()`), or one SFX pattern, to a single `AudioStreamWAV`. Costs nothing to play; no longer follows the chord progression, because it is a recording of one.
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
   To bake from the Synth tab, write that tool as an `EditorScript` (a `@tool` script extending `EditorScript` whose `_run()` bakes every set) and name it in the project setting `godot_synth/bake/tool_script` (Project Settings, Godot Synth > Bake; a `res://` path, e.g. `res://tools/bake_samples.gd`). The tab's **Bake** button then asks for confirmation and runs that `_run()`, the same as File > Run in the script editor, and refreshes the chip when it is done. The editor is busy while it runs, and unsaved patch edits are baked as they are in the editor. Unset (or not an `EditorScript`), the button is disabled and its tooltip says why.
2. Put `synth_sampler.gd` on the node where `synth_engine.gd` was (an autoload scene, say) and point `samples_dir` at the sets. Nothing that drives the synth changes.
3. A patch with no file of its own (made in code, or embedded in a scene) has no set to look up: hand it one with `set_patch_sample_set(patch, set)`. A patch with no set leaves its channel silent, with one warning.

What it cannot reproduce (pan, the filter envelope's release, exact timing) is listed at the top of `synth_sampler.gd` and `sample_set.gd`. `mix_rate` and `buffer_length` mean nothing to it; `configure()` applies only `max_voices`.

To compare it with the live engine by ear, set `live = true` on the node before it enters the tree (from a subclass's `_init()`, say, keyed off a command-line flag). Every method then hands to `SynthEngine`'s and the node is the plain live synth.

## Channel allocation

The synth has 16 channels. Each holds one `SynthPatch` and gets its own `AudioServer` bus (named `Ch{N}`) routed to wherever you want via `output_bus`. Two tracks sharing a channel will share its patch and effect chain — fine for some uses, surprising for others. A track with a drum kit takes one channel per piece, starting at its `synth_channel`. There's a 24-voice global pool; voice stealing is "oldest wins."

## Performance notes

GDScript per-sample audio rendering is CPU-bound but runs comfortably for ~16 active voices at 22050 Hz on a modern desktop. Bump `mix_rate` to 44100 if your saws sound aliased. Drop `max_voices` if your Steam Deck is angry. Enabling FM, the resonant filter, or many noise voices increases per-voice cost — most patches use only a subset.

## License

MIT. Do whatever you want, attribution appreciated, no warranty if the FM index of 8.0 makes your speakers leave.

## Credits

Built incrementally for [3dimenshift](https://github.com/lost-conn) and extracted as a standalone addon. Patches contributed willingly. Bug reports contributed reluctantly.
