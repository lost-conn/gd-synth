@tool
class_name SynthMainScreen
extends VBoxContainer

# The Synth tab's main screen. A top bar over three views:
#
#   Sound    the patch rack (browser, module cards, audition keyboard)
#   Pattern  the pattern editor (piano roll + inspector)
#   Track    a read-only list of a music scene's MusicTracks (placeholder)
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
const PatternEditorScene := preload("./pattern_editor.tscn")
const TrackViewScript := preload("./synth_track_view.gd")
const PreviewScript := preload("./synth_preview.gd")

signal mode_changed(mode: int)

## The shared preview rig (engine + director + track). Built on first use.
var preview: SynthPreview
## Right side of the top bar: the sound's sample-bake status, set by the Sound
## view through set_bake_status().
var bake_chip: PanelContainer
## The editor's EditorUndoRedoManager (EditorPlugin.get_undo_redo()), which the
## Sound view records its edits in. Set it before or after the tab is built.
var undo_redo: Object:
	set(v):
		undo_redo = v
		if _patch_rack != null:
			_patch_rack.undo_redo = v

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
var _highlight_block: int = -1

var _content: Control
var _sound_view: Control
var _patch_rack: SynthPatchRack
var _pattern_view: ScrollContainer
var _pattern_editor: PanelContainer
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
	if preview != null and is_instance_valid(preview):
		preview.stop()

# ---------------------------------------------------------------------------
# Public API (what plugin.gd calls)
# ---------------------------------------------------------------------------

## The tab became visible (true) or hidden (false). Hidden: stop playback and
## silence the engine's render thread.
func set_active(active: bool) -> void:
	if active:
		_ensure_started()
		preview.resume()
		_patch_rack.rescan()
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
	_pattern_editor.current_path = _saved_path(p)
	_pattern_editor.set_pattern(p)
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

func get_pattern_editor() -> Control:
	return _pattern_editor

func get_track_view() -> SynthTrackView:
	return _track_view

## Play the Pattern view's pattern through the shared preview.
func play() -> void:
	_ensure_started()
	_pattern_editor.start_preview()

func stop() -> void:
	preview.stop()

## Set the chip at the right of the top bar. The Sound view calls this with the
## patch's bake status; a host may too.
func set_bake_status(text: String, tooltip: String = "", color: Color = Color(0.7, 0.72, 0.78)) -> void:
	_bake_label.text = text
	_bake_label.add_theme_color_override("font_color", color)
	bake_chip.tooltip_text = tooltip

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
	_play_btn.tooltip_text = "Play the Pattern view's pattern through the current patch and MusicData."
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

	# Bake-status chip, right-aligned. The Sound view fills it.
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

	# Pattern: the editor's toolbars are wider than a docked main screen can be,
	# so it scrolls instead of dragging the editor window's minimum size up.
	_pattern_view = ScrollContainer.new()
	_pattern_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.add_child(_pattern_view)
	_pattern_editor = PatternEditorScene.instantiate()
	_pattern_editor.custom_minimum_size = Vector2(1000, 460)
	_pattern_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pattern_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pattern_view.add_child(_pattern_editor)

	# Track.
	_track_view = TrackViewScript.new()
	_track_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_track_view.music_data_offered.connect(open_music_data)
	_content.add_child(_track_view)

func _build_dialogs() -> void:
	_data_dialog = FileDialog.new()
	_data_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_data_dialog.access = FileDialog.ACCESS_RESOURCES
	_data_dialog.filters = PackedStringArray(["*.tres ; MusicData Resource"])
	_data_dialog.size = Vector2i(720, 520)
	_data_dialog.file_selected.connect(_on_data_file_chosen)
	add_child(_data_dialog)

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
	_pattern_editor.bind_preview(preview)
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

func _on_data_file_chosen(path: String) -> void:
	var res := load(path)
	if res is MusicData:
		set_music_data(res)
	else:
		push_warning("[SynthMainScreen] Not a MusicData: " + path)

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
		out.append(NOTE_NAMES[b.chord_root % 12] + chord_suffix(b.chord_intervals))
	return out

static func scale_name(iv: PackedInt32Array) -> String:
	var table := [
		["Major", MusicData.MAJOR], ["Minor", MusicData.MINOR], ["Dorian", MusicData.DORIAN],
		["Phrygian", MusicData.PHRYGIAN], ["Lydian", MusicData.LYDIAN],
		["Mixolydian", MusicData.MIXOLYDIAN], ["Penta Major", MusicData.PENTA_MAJOR],
		["Penta Minor", MusicData.PENTA_MINOR], ["Blues", MusicData.BLUES],
		["Chromatic", MusicData.CHROMATIC],
	]
	for e in table:
		if iv == e[1]:
			return e[0]
	return "(custom scale)"

static func chord_suffix(iv: PackedInt32Array) -> String:
	var table := [
		["", MusicData.CHORD_MAJ], ["m", MusicData.CHORD_MIN], ["dim", MusicData.CHORD_DIM],
		["aug", MusicData.CHORD_AUG], ["maj7", MusicData.CHORD_MAJ7], ["m7", MusicData.CHORD_MIN7],
		["7", MusicData.CHORD_DOM7], ["sus2", MusicData.CHORD_SUS2], ["sus4", MusicData.CHORD_SUS4],
	]
	for e in table:
		if iv == e[1]:
			return e[0]
	return "*"
