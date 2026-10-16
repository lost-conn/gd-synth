@tool
class_name SynthMainScreen
extends VBoxContainer

# The Synth tab's main screen. A top bar over three views:
#
#   Sound    the patch rack (browser, module cards, audition keyboard)
#   Pattern  the pattern editor (piano roll, velocity lane, inspector)
#   Track    the song arranger: a music scene's progression and one lane per
#            MusicTrack, played together
#
# Everything the views play goes through ONE SynthPreview owned here: one
# engine, one director, one track, never the game's /root/Synth or /root/Music.
# The "current patch" is shared state on it: the Sound view edits that patch in
# place, so switching to Pattern and pressing Play plays the pattern with the
# patch as it is right now.
#
# The EditorPlugin (plugin.gd) hosts this in the editor's main screen, but it
# has no editor-only dependency: it also runs from any scene or script.

enum Mode { SOUND, PATTERN, TRACK }

const MODE_NAMES := ["Sound", "Pattern", "Track"]
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const PatchRackScript := preload("./synth_patch_rack.gd")
const PatternViewScript := preload("./synth_pattern_view.gd")
const TrackViewScript := preload("./synth_track_view.gd")
const PreviewScript := preload("./synth_preview.gd")

signal mode_changed(mode: int)
## The song context changed: the music scene whose other tracks the Pattern view
## draws faintly (null = none).
signal song_context_changed(ctx: SynthSongContext)

## The shared preview rig (engine + director + track). Built on first use.
var preview: SynthPreview
## Right side of the top bar: the sound's sample-bake status, set by the Sound
## view through set_bake_status().
var bake_chip: PanelContainer
## The editor's EditorUndoRedoManager (EditorPlugin.get_undo_redo()), which the
## Sound and Pattern views record their edits in. Set it before or after the tab
## is built.
var undo_redo: Object:
	set(v):
		undo_redo = v
		if _patch_rack != null:
			_patch_rack.undo_redo = v
		if _pattern_view != null:
			_pattern_view.undo_redo = v
		if _track_view != null:
			_track_view.undo_redo = v
## The song the Pattern view draws around its pattern: a music scene's tracks.
## Chosen in the Track view, or worked out from the MusicTrack that plays the
## pattern being edited (then song_context.inferred is true). Null = none.
## A scene picked in the Track view also lends the preview its MusicData.
var song_context: SynthSongContext

var _mode: int = Mode.SOUND
var _started: bool = false

var _mode_buttons: Array[Button] = []
var _play_btn: Button
var _stop_btn: Button
var _loop_btn: Button
var _data_name: Label
var _data_default_btn: Button
var _bpm_label: Label
var _key_label: Label
var _prog_box: HBoxContainer
var _prog_chips: Array[Label] = []
var _bake_label: Label
var _bake_btn: Button
var _bake_dialog: ConfirmationDialog
var _baking: bool = false
var _highlight_block: int = -1

var _content: Control
var _sound_view: Control
var _patch_rack: SynthPatchRack
var _pattern_view: SynthPatternView
var _track_view: SynthTrackView
var _data_dialog: FileDialog

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	preview = PreviewScript.new()
	preview.name = "Preview"
	preview.patch_changed.connect(_on_preview_patch_changed)
	preview.music_data_changed.connect(func(_d): _refresh_readout())
	preview.playing_changed.connect(_on_playing_changed)
	add_child(preview)

	_build_bar()
	add_child(HSeparator.new())
	_build_views()
	_build_dialogs()
	if ProjectSettings.has_signal(&"settings_changed"):
		ProjectSettings.settings_changed.connect(refresh_bake_button)
	refresh_bake_button()

	# Start from the preview's patch, so the Sound view is never blank and the
	# first Play in Pattern has a patch. (No engine yet: the UI only.)
	_patch_rack.set_patch(preview.get_effective_patch())
	set_mode(Mode.SOUND)
	_refresh_readout()
	_apply_icons()

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_icons()

func _exit_tree() -> void:
	if ProjectSettings.has_signal(&"settings_changed") and ProjectSettings.settings_changed.is_connected(refresh_bake_button):
		ProjectSettings.settings_changed.disconnect(refresh_bake_button)
	if preview != null and is_instance_valid(preview):
		preview.stop()

# ---------------------------------------------------------------------------
# Public API (what plugin.gd calls)
# ---------------------------------------------------------------------------

## The tab became visible (true) or hidden (false). Hidden: stop playback and
## silence the engine's render thread.
func set_active(active: bool) -> void:
	if active:
		refresh_bake_button()
		_ensure_started()
		preview.resume()
		_patch_rack.rescan()
		_track_view.refresh(true)
	else:
		_patch_rack.release_keys()
		preview.suspend()

func set_mode(mode: int) -> void:
	_mode = clampi(mode, 0, MODE_NAMES.size() - 1)
	for i in _mode_buttons.size():
		_mode_buttons[i].set_pressed_no_signal(i == _mode)
	_sound_view.visible = _mode == Mode.SOUND
	_pattern_view.visible = _mode == Mode.PATTERN
	_track_view.visible = _mode == Mode.TRACK
	if _mode == Mode.PATTERN:
		_ensure_started()
		_pattern_view.focus_roll.call_deferred()
	if _mode == Mode.TRACK:
		_ensure_started()
		# A song context the Pattern view found is the song to arrange.
		if _track_view.scene_path == "" and song_context != null and song_context.scene_path != "":
			_track_view.set_scene(song_context.scene_path, false)
		else:
			_track_view.refresh(true)
		_track_view.focus_view.call_deferred()
	_update_play_tip()
	mode_changed.emit(_mode)

func get_mode() -> int:
	return _mode

## Edit [param p] in the Sound view. It becomes the shared current patch.
func open_patch(p: SynthPatch) -> void:
	if p == null:
		return
	_ensure_started()
	_patch_rack.open_patch(p, _saved_path(p))
	set_mode(Mode.SOUND)

## Edit [param p] in the Pattern view.
func open_pattern(p: MusicPattern) -> void:
	if p == null:
		return
	_ensure_started()
	_pattern_view.open_pattern(p, _saved_path(p))
	set_mode(Mode.PATTERN)

## Preview against [param d] (null = the built-in default). Shows the Pattern view.
func open_music_data(d: MusicData) -> void:
	set_music_data(d)
	set_mode(Mode.PATTERN)

func set_music_data(d: MusicData) -> void:
	preview.set_music_data(d)

## The patch Sound edits and Pattern plays.
func get_current_patch() -> SynthPatch:
	return preview.get_effective_patch()

## The Sound view.
func get_patch_rack() -> SynthPatchRack:
	return _patch_rack

## Same as get_patch_rack(); the name phase 1 gave it.
func get_patch_editor() -> Control:
	return _patch_rack

func get_pattern_view() -> SynthPatternView:
	return _pattern_view

## Same as get_pattern_view(); the name phase 1 gave it.
func get_pattern_editor() -> Control:
	return _pattern_view

func get_track_view() -> SynthTrackView:
	return _track_view

## Play through the shared preview: the whole song in Track, the Pattern view's
## pattern anywhere else.
func play() -> void:
	_ensure_started()
	if _mode == Mode.TRACK:
		_track_view.start_song()
	else:
		_pattern_view.start_preview()

func stop() -> void:
	preview.stop()

## Make [param ctx] the song context (null clears it). [param inferred]: it was
## found from the pattern, not picked.
func set_song_context(ctx: SynthSongContext, inferred: bool = false) -> void:
	var prev := song_context
	if ctx != null:
		ctx.inferred = inferred
	song_context = ctx
	# The song's own MusicData is what its tracks are played against, so the
	# preview takes it up first: the Pattern view resolves the other tracks'
	# pitches against it. A scene that was picked always lends it (when it is new,
	# or its MusicData changed); one only inferred from a pattern does not
	# override a MusicData that was chosen.
	if ctx != null and ctx.music_data != null:
		var adopt := false
		if inferred:
			adopt = preview.music_data == null
		else:
			adopt = prev == null or prev.scene_path != ctx.scene_path or prev.music_data != ctx.music_data
		if adopt:
			set_music_data(ctx.music_data)
	_pattern_view.set_song_context(ctx)
	song_context_changed.emit(ctx)

## Make the patch file at [param path] the current patch, without leaving the
## current view. (The Sound view asks first if its patch has unsaved edits.)
func use_patch(path: String) -> void:
	var res := ResourceLoader.load(path)
	if res is SynthPatch:
		_ensure_started()
		_patch_rack.open_patch(res, path)
	else:
		push_warning("[SynthMainScreen] Not a SynthPatch: " + path)

## The editor's open scenes changed (EditorPlugin.scene_changed / scene_closed):
## the Track view re-checks whether its music scene is open.
func editor_scenes_changed() -> void:
	if _track_view != null:
		_track_view.editor_scenes_changed()

## Set the chip at the right of the top bar. The Sound view calls this with the
## patch's bake status; a host may too.
func set_bake_status(text: String, tooltip: String = "", color: Color = Color(0.7, 0.72, 0.78)) -> void:
	_bake_label.text = text
	_bake_label.add_theme_color_override("font_color", color)
	bake_chip.tooltip_text = tooltip

## Enable or disable the Bake button for the project's bake tool setting
## (SynthBakeInfo.BAKE_TOOL_SETTING), and word its tooltip.
func refresh_bake_button() -> void:
	if _bake_btn == null:
		return
	var path := SynthBakeInfo.bake_tool_path()
	var problem := SynthBakeInfo.bake_tool_problem(path)
	_bake_btn.disabled = problem != "" or _baking
	if problem == "":
		_bake_btn.tooltip_text = "Bake every sample set with %s. Takes a minute or two; the editor is busy meanwhile." % path
		return
	var lines := PackedStringArray([problem])
	lines.append("Set an EditorScript that bakes your project's sample sets in Project Settings (%s)." % SynthBakeInfo.BAKE_TOOL_SETTING)
	var tools: PackedStringArray = _patch_rack.index.bake_tools if _patch_rack != null else PackedStringArray()
	if not tools.is_empty():
		lines.append("Bake tool script(s) found: " + ", ".join(tools.slice(0, 3)))
	_bake_btn.tooltip_text = "\n".join(lines)

## Run the project's bake tool (its EditorScript's _run()) once, then refresh the
## bake chip from the fresh sets. Ignored while a bake is already running. The
## editor is busy for the length of the bake.
func run_bake() -> void:
	if _baking:
		return
	var path := SynthBakeInfo.bake_tool_path()
	var problem := SynthBakeInfo.bake_tool_problem(path)
	if problem != "":
		push_error("[SynthMainScreen] Cannot bake: " + problem)
		set_bake_status("Bake failed", problem, SynthRackStyle.warn(self))
		return
	_baking = true
	refresh_bake_button()
	set_bake_status("Baking...", "Baking every sample set with %s. The editor is busy until it finishes." % path,
			SynthRackStyle.accent(self))
	# Let the chip paint before the editor freezes.
	await get_tree().process_frame
	await get_tree().process_frame
	var tool_script := load(path) as GDScript
	var bake_tool: Object = tool_script.new() if tool_script != null and tool_script.can_instantiate() else null
	if bake_tool == null:
		var msg := "%s could not be instantiated." % path
		push_error("[SynthMainScreen] " + msg)
		set_bake_status("Bake failed", msg, SynthRackStyle.warn(self))
		_baking = false
		refresh_bake_button()
		return
	# The scan the tool (or we) start finishes later: look at the sets again then.
	var fs := _editor_fs()
	if fs != null and not fs.is_connected("filesystem_changed", _on_bake_files_changed):
		fs.connect("filesystem_changed", _on_bake_files_changed, CONNECT_ONE_SHOT)
	bake_tool.call("_run")
	if fs != null:
		fs.call("scan")
	_baking = false
	refresh_bake_button()
	_refresh_after_bake()

func _on_bake_files_changed() -> void:
	_refresh_after_bake()

# Re-read the sets and re-decide the chip (the bake tool may have rewritten them).
func _refresh_after_bake() -> void:
	if _patch_rack == null or _baking:
		return
	_patch_rack.rescan()
	_track_view.refresh(true)
	if _patch_rack.patch == null:
		set_bake_status("No patch", "The sample-bake status of the patch in the Sound view shows here.")

static func _editor_fs() -> Object:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		return Engine.get_singleton(&"EditorInterface").call("get_resource_filesystem")
	return null

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_bar() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	add_child(bar)

	var left := HFlowContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("h_separation", 12)
	left.add_theme_constant_override("v_separation", 4)
	bar.add_child(left)

	# Mode switch.
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 0)
	left.add_child(modes)
	var group := ButtonGroup.new()
	for i in MODE_NAMES.size():
		var b := Button.new()
		b.text = MODE_NAMES[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(76, 0)
		b.pressed.connect(set_mode.bind(i))
		modes.add_child(b)
		_mode_buttons.append(b)

	# Transport.
	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 4)
	left.add_child(transport)
	_play_btn = Button.new()
	_play_btn.text = "Play"
	_play_btn.pressed.connect(play)
	transport.add_child(_play_btn)
	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(stop)
	transport.add_child(_stop_btn)
	_loop_btn = Button.new()
	_loop_btn.text = "Loop"
	_loop_btn.toggle_mode = true
	_loop_btn.button_pressed = true
	_loop_btn.tooltip_text = "On: loop until stopped. Off: play once through the progression (or the pattern, if longer), then stop."
	_loop_btn.toggled.connect(func(on: bool): preview.loop = on)
	transport.add_child(_loop_btn)

	# MusicData chooser + readout.
	var data := HBoxContainer.new()
	data.add_theme_constant_override("separation", 6)
	left.add_child(data)
	var data_lbl := Label.new()
	data_lbl.text = "MusicData:"
	data.add_child(data_lbl)
	_data_name = Label.new()
	_data_name.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	data.add_child(_data_name)
	var data_btn := Button.new()
	data_btn.text = "Choose..."
	data_btn.tooltip_text = "Tempo and chord progression the pattern is previewed against."
	data_btn.pressed.connect(func(): _data_dialog.popup_centered())
	data.add_child(data_btn)
	_data_default_btn = Button.new()
	_data_default_btn.text = "Default"
	_data_default_btn.tooltip_text = "Go back to the built-in default (120 BPM, C major, one block)."
	_data_default_btn.pressed.connect(func(): set_music_data(null))
	data.add_child(_data_default_btn)

	var readout := HBoxContainer.new()
	readout.add_theme_constant_override("separation", 10)
	left.add_child(readout)
	_bpm_label = Label.new()
	readout.add_child(_bpm_label)
	_key_label = Label.new()
	readout.add_child(_key_label)
	_prog_box = HBoxContainer.new()
	_prog_box.add_theme_constant_override("separation", 6)
	readout.add_child(_prog_box)

	# Bake button, then the bake-status chip: right-aligned.
	_bake_btn = Button.new()
	_bake_btn.text = "Bake"
	_bake_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bake_btn.pressed.connect(_on_bake_pressed)
	bar.add_child(_bake_btn)

	# Bake-status chip. The Sound view fills it.
	bake_chip = PanelContainer.new()
	bake_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.07)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	bake_chip.add_theme_stylebox_override("panel", sb)
	_bake_label = Label.new()
	bake_chip.add_child(_bake_label)
	bar.add_child(bake_chip)
	set_bake_status("No patch", "The sample-bake status of the patch in the Sound view shows here.")

func _build_views() -> void:
	_content = Control.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.clip_contents = true
	add_child(_content)

	# Sound: the patch rack lays itself out (cards wrap to the width, the browser
	# folds away on a narrow tab), so it fills the view and scrolls its own cards.
	_patch_rack = PatchRackScript.new()
	_patch_rack.preview = preview
	_patch_rack.undo_redo = undo_redo
	_patch_rack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_patch_rack.patch_changed.connect(_on_patch_editor_changed)
	_patch_rack.bake_status_changed.connect(set_bake_status)
	_sound_view = _patch_rack
	_content.add_child(_patch_rack)

	# Pattern: lays itself out (the header wraps, the inspector folds away on a
	# narrow tab), so it fills the view.
	_pattern_view = PatternViewScript.new()
	_pattern_view.undo_redo = undo_redo
	_pattern_view.index = _patch_rack.index
	_pattern_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pattern_view.sound_requested.connect(set_mode.bind(Mode.SOUND))
	_pattern_view.patch_requested.connect(use_patch)
	_pattern_view.song_context_inferred.connect(func(ctx): set_song_context(ctx, true))
	_content.add_child(_pattern_view)

	# Track: lays itself out (the inspector folds away on a narrow tab).
	_track_view = TrackViewScript.new()
	_track_view.undo_redo = undo_redo
	_track_view.index = _patch_rack.index
	_track_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_track_view.song_context_changed.connect(_on_track_context_changed)
	_track_view.pattern_requested.connect(_on_track_pattern_requested)
	_track_view.patch_requested.connect(open_patch)
	_track_view.music_data_edited.connect(_refresh_readout)
	_content.add_child(_track_view)

func _build_dialogs() -> void:
	_data_dialog = FileDialog.new()
	_data_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_data_dialog.access = FileDialog.ACCESS_RESOURCES
	_data_dialog.filters = PackedStringArray(["*.tres ; MusicData Resource"])
	_data_dialog.size = Vector2i(720, 520)
	_data_dialog.file_selected.connect(_on_data_file_chosen)
	add_child(_data_dialog)

	_bake_dialog = ConfirmationDialog.new()
	_bake_dialog.title = "Bake sample sets"
	_bake_dialog.ok_button_text = "Bake"
	_bake_dialog.dialog_autowrap = true
	_bake_dialog.min_size = Vector2i(Vector2(460, 0) * SynthRackStyle.scale(self))
	_bake_dialog.confirmed.connect(run_bake)
	add_child(_bake_dialog)

func _on_bake_pressed() -> void:
	if _baking:
		return
	_bake_dialog.dialog_text = "Bake every sample set with %s?\nTakes a minute or two; the editor is busy meanwhile. Unsaved patch edits are baked as they are in the editor." % SynthBakeInfo.bake_tool_path()
	_bake_dialog.popup_centered()

# Editor-theme icons when the editor theme is inherited (inside the editor);
# plain text buttons anywhere else.
func _apply_icons() -> void:
	if _play_btn == null:
		return
	var pairs := [[_play_btn, "Play"], [_stop_btn, "Stop"], [_loop_btn, "Loop"]]
	for pr in pairs:
		var b: Button = pr[0]
		b.icon = get_theme_icon(pr[1], "EditorIcons") if has_theme_icon(pr[1], "EditorIcons") else null

# Bind the views to the preview rig the first time the tab is needed.
func _ensure_started() -> void:
	if _started:
		return
	_started = true
	preview.ensure_started()
	_pattern_view.bind_preview(preview)
	_track_view.bind_preview(preview)
	preview.director.block_changed.connect(_on_block_changed)

# ---------------------------------------------------------------------------
# Shared state plumbing
# ---------------------------------------------------------------------------

# Sound changed its patch (preset, New, a browser pick, or opened from the filesystem).
func _on_patch_editor_changed(p: SynthPatch) -> void:
	preview.set_patch(p)

# The preview's patch changed from elsewhere (the Pattern view's Load Patch):
# Sound follows, so it edits what Pattern plays.
func _on_preview_patch_changed(p: SynthPatch) -> void:
	if p != null and p != _patch_rack.patch:
		_patch_rack.open_patch(p, _saved_path(p), true)

# The Track view's song changed (a scene was picked or cleared, or its tracks were
# edited): that is the song context.
func _on_track_context_changed(ctx: SynthSongContext) -> void:
	set_song_context(ctx, false)

# A clip was double-clicked in the Track view: edit its pattern, hearing it through
# the track's own patch, with the scene as the song context.
func _on_track_pattern_requested(pattern: MusicPattern, patch: SynthPatch) -> void:
	_ensure_started()
	var ctx := _track_view.make_context()
	if ctx != null and (song_context == null or song_context.scene_path != ctx.scene_path or song_context.inferred):
		set_song_context(ctx, false)
	if patch != null:
		var path := _saved_path(patch)
		if path != "":
			use_patch(path)
		else:
			_patch_rack.open_patch(patch, "")
	open_pattern(pattern)

func _on_data_file_chosen(path: String) -> void:
	var res := load(path)
	if res is MusicData:
		set_music_data(res)
	else:
		push_warning("[SynthMainScreen] Not a MusicData: " + path)

func _update_play_tip() -> void:
	if _play_btn == null:
		return
	if _mode == Mode.TRACK:
		_play_btn.tooltip_text = "Play every track of the song together, from the playhead, through the current MusicData. Mute and solo apply."
	else:
		_play_btn.tooltip_text = "Play the Pattern view's pattern through the current patch and MusicData."

func _on_playing_changed(playing: bool) -> void:
	_stop_btn.disabled = not playing
	_play_btn.text = "Restart" if playing else "Play"
	if not playing:
		_highlight_block = -1
		_update_chips()

func _on_block_changed(_block: MusicBlock, index: int) -> void:
	_highlight_block = index
	_update_chips()

static func _saved_path(res: Resource) -> String:
	if res == null or res.resource_path == "" or "::" in res.resource_path:
		return ""
	return res.resource_path

# ---------------------------------------------------------------------------
# Readout: BPM, key, progression
# ---------------------------------------------------------------------------

func _refresh_readout() -> void:
	var d: MusicData = preview.get_effective_music_data()
	if preview.is_using_default_data():
		_data_name.text = "(default)"
	else:
		_data_name.text = _saved_path(d).get_file() if _saved_path(d) != "" else "(inline)"
	_data_default_btn.disabled = preview.is_using_default_data()
	_bpm_label.text = "%s BPM" % _fmt_bpm(d.bpm)
	_key_label.text = key_text(d)
	for c in _prog_chips:
		c.queue_free()
	_prog_chips.clear()
	var names := chord_names(d)
	for i in names.size():
		var l := Label.new()
		l.text = names[i]
		l.tooltip_text = "Block %d: %d beats" % [i + 1, d.blocks[i].duration_beats]
		_prog_box.add_child(l)
		_prog_chips.append(l)
	_highlight_block = -1
	_update_chips()

func _update_chips() -> void:
	for i in _prog_chips.size():
		var on: bool = i == _highlight_block
		_prog_chips[i].add_theme_color_override("font_color", Color(1.0, 0.82, 0.35) if on else Color(0.7, 0.72, 0.78))

static func _fmt_bpm(bpm: float) -> String:
	return "%d" % int(bpm) if is_equal_approx(bpm, roundf(bpm)) else "%.1f" % bpm

## "C Major", or "C Major, modulates" when blocks use different scales.
static func key_text(d: MusicData) -> String:
	if d == null or d.blocks.is_empty():
		return "-"
	var first: MusicBlock = d.blocks[0]
	var txt := "%s %s" % [NOTE_NAMES[first.scale_root % 12], scale_name(first.scale_intervals)]
	for b in d.blocks:
		if b.scale_root != first.scale_root or b.scale_intervals != first.scale_intervals:
			return txt + ", modulates"
	return txt

## One chord symbol per block: ["C", "G", "Am", "F"].
static func chord_names(d: MusicData) -> PackedStringArray:
	var out := PackedStringArray()
	if d == null:
		return out
	for b in d.blocks:
		out.append(SynthHarmony.chord_name(b))
	return out

static func scale_name(iv: PackedInt32Array) -> String:
	return SynthHarmony.scale_name(iv)

static func chord_suffix(iv: PackedInt32Array) -> String:
	return SynthHarmony.chord_suffix(iv)
