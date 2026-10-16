@tool
class_name SynthTrackView
extends VBoxContainer

# The Synth tab's Track view: the song arranger.
#
#   header      the music scene (pick it, reload it, open it in the editor), the
#               song's BPM and a swing for the preview, the MusicData being played,
#               a chip that says how many patches need a re-bake, Add track and
#               the inspector toggle
#   top lane    the progression: one chip per MusicBlock, sized by its length
#   ruler       beats and bars; click or drag to move the playhead
#   lanes       one per MusicTrack: name, type, mute and solo, and its pattern as
#               a clip repeating across the timeline (two trips through the
#               progression, or the longest pattern if that is longer)
#   drawer      the selected block's chord, scale and length, and add / move / remove
#   inspector   the selected track's own settings, collapsible
#
# WHO EDITS WHAT.
#   Tracks     are edited only through the scene's live nodes. If the music scene is
#              open in the editor the view holds its edited nodes and every change is
#              an EditorUndoRedoManager action with the node as context, so Ctrl+S
#              saves it and the scene tab shows as modified. If it is not open the
#              view reads a detached copy and everything about tracks is read-only
#              until "Open scene to edit". The view never packs or saves a scene.
#   Blocks     belong to the MusicData the preview plays (a .tres of its own, usually
#              the one the scene's MusicDataPlayer holds): edited in place with
#              undo, the resource marked edited, saved with the header's Save.
#
# PLAYBACK. Play in Track mode plays every lane together through the shared
# SynthPreview (play_song): each lane on its own channel with its own patch, mute
# and solo honoured. The playhead is a layer of its own, so only it repaints.

## A scene was picked or cleared (path "" = cleared).
signal scene_changed(path: String)
## What the Pattern view should know about the song changed: the tracks as the view
## sees them now (null = no scene).
signal song_context_changed(ctx: SynthSongContext)
## A clip was double-clicked: edit [param pattern] in Pattern, hearing it through
## [param patch] (null if the track has none).
signal pattern_requested(pattern: MusicPattern, patch: SynthPatch)
## Edit [param patch] in Sound.
signal patch_requested(patch: SynthPatch)
## The progression or tempo of the MusicData was edited.
signal music_data_edited

const INSPECTOR_WIDTH := 290.0
# Below this width (editor scale 1) the inspector folds away unless asked for.
const INSPECTOR_AUTO_HIDE := 900.0
const POLL_SECONDS := 0.25

## The editor's EditorUndoRedoManager. Null: edits apply directly, with no history.
var undo_redo: Object:
	set(v):
		undo_redo = v
		_edit.undo_redo = v
## The project index (shared with the other views), for the bake chip.
var index: SynthProjectIndex
var scene_path: String = ""
## True when the scene is open in the editor and the tracks are its live nodes.
var live: bool = false
## The MusicTracks of the scene, in tree order.
var tracks: Array[MusicTrack] = []
## The MusicData in the scene's MusicDataPlayer (null: none).
var scene_data: MusicData
var timeline := SynthTimeline.new()
var selected_path: String = ""
var muted: Dictionary = {}
var soloed: Dictionary = {}

var _edit := SynthSongEdit.new()
var _preview: SynthPreview
var _root: Node
var _detached: Node
var _mtime: int = 0
var _sig: String = ""
var _selected_block: int = -1
var _cursor_beat: float = 0.0
var _song_started: bool = false
var _swing: float = 0.0
var _swing_read: bool = false
var _inspector_pref: int = -1       # -1 auto, 0 hidden, 1 shown
var _built: bool = false
var _lanes: Array[SynthTrackLane] = []
var _clean_data: MusicData
var _clean_fp: String = ""
var _edited_flag: bool = false
var _bake_infos: Dictionary = {}    # patch path -> SynthBakeInfo.Info
var _history_queued: bool = false
var _announce_clear: bool = false
var _data_key: String = ""
var _ctx_sig: String = "\u0001"
var _playing_specs: Array = []

var _path_label: Label
var _state_label: Label
var _open_btn: Button
var _bpm_spin: SpinBox
var _swing_spin: SpinBox
var _data_label: Label
var _save_btn: Button
var _bake_chip: PanelContainer
var _bake_label: Label
var _add_btn: Button
var _inspector_btn: Button
var _page: VBoxContainer
var _prog_gutter: Control
var _ruler_gutter: Control
var _stage: Control
var _prog_lane: SynthProgressionLane
var _ruler: SynthSongRuler
var _lane_box: VBoxContainer
var _empty_label: Label
var _playhead: SynthSongPlayhead
var _drawer: PanelContainer
var _drawer_title: Label
var _blk_root: OptionButton
var _blk_quality: OptionButton
var _blk_sroot: OptionButton
var _blk_scale: OptionButton
var _chord_editor: SynthIntervalEditor
var _scale_editor: SynthIntervalEditor
# The block whose "Custom..." editor was opened while its intervals still match a
# preset (so there is nothing in the data to say it is custom yet). Cleared by
# picking a preset or by selecting another block.
var _open_chord_custom: MusicBlock
var _open_scale_custom: MusicBlock
var _blk_beats: SpinBox
var _blk_left: Button
var _blk_right: Button
var _blk_remove: Button
var _drawer_labels: Array = []
var _blk_add: Button
var _inspector: SynthTrackInspector
var _dialog: FileDialog
var _timer: Timer

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)
	# Everything scrolls together if the tab is too small for it, rather than the
	# lanes being squeezed out.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 6)
	scroll.add_child(_page)
	_build_header()
	_build_body()
	_build_dialogs()
	_timer = Timer.new()
	_timer.wait_time = POLL_SECONDS
	_timer.timeout.connect(_on_poll)
	add_child(_timer)
	_timer.start()
	visibility_changed.connect(_on_visibility_changed)
	if undo_redo != null and undo_redo.has_signal(&"history_changed"):
		undo_redo.connect(&"history_changed", _on_history_changed)
	_built = true
	_relayout()
	_rebuild()

func _exit_tree() -> void:
	if undo_redo != null and is_instance_valid(undo_redo) and undo_redo.has_signal(&"history_changed") \
			and undo_redo.is_connected(&"history_changed", _on_history_changed):
		undo_redo.disconnect(&"history_changed", _on_history_changed)
	_free_detached()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _built:
		_relayout()
	elif what == NOTIFICATION_THEME_CHANGED:
		_apply_icons()

func _s() -> float:
	return SynthRackStyle.scale(self)

func _build_header() -> void:
	var s := _s()
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 4)
	_page.add_child(bar)

	bar.add_child(_head_label("Music scene"))
	var pick := Button.new()
	pick.text = "Choose..."
	pick.focus_mode = Control.FOCUS_NONE
	pick.tooltip_text = "Pick a .tscn that holds MusicTrack nodes (for example a level's music scene)."
	pick.pressed.connect(func(): _dialog.popup_centered())
	bar.add_child(pick)
	var reload := Button.new()
	reload.text = "Reload"
	reload.focus_mode = Control.FOCUS_NONE
	reload.tooltip_text = "Read the scene again."
	reload.pressed.connect(func(): refresh(true))
	bar.add_child(reload)
	_path_label = Label.new()
	_path_label.text = "(none)"
	_path_label.custom_minimum_size.x = 150.0 * s
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_path_label.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_path_label)
	_state_label = Label.new()
	_state_label.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_state_label)
	_open_btn = Button.new()
	_open_btn.text = "Open scene"
	_open_btn.focus_mode = Control.FOCUS_NONE
	_open_btn.pressed.connect(open_scene_in_editor)
	bar.add_child(_open_btn)

	bar.add_child(_head_label("BPM"))
	_bpm_spin = SpinBox.new()
	_bpm_spin.min_value = 20.0
	_bpm_spin.max_value = 400.0
	_bpm_spin.step = 0.01
	_bpm_spin.custom_minimum_size.x = 100.0 * s
	_bpm_spin.tooltip_text = "The song's tempo: MusicData.bpm."
	_bpm_spin.value_changed.connect(_on_bpm_changed)
	bar.add_child(_bpm_spin)
	bar.add_child(_head_label("Swing"))
	_swing_spin = SpinBox.new()
	_swing_spin.min_value = 0.0
	_swing_spin.max_value = 1.0
	_swing_spin.step = 0.01
	_swing_spin.custom_minimum_size.x = 84.0 * s
	_swing_spin.tooltip_text = "Delays every offbeat eighth note (0.33 is about triplet swing). Swing is a property of the game's MusicDirector, not of the song, so this only changes the preview; it starts at the project's Music autoload."
	_swing_spin.value_changed.connect(_on_swing_changed)
	bar.add_child(_swing_spin)

	bar.add_child(_head_label("MusicData"))
	_data_label = Label.new()
	_data_label.add_theme_color_override("font_color", SynthRackStyle.accent(self))
	_data_label.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_data_label)
	_save_btn = Button.new()
	_save_btn.text = "Save"
	_save_btn.focus_mode = Control.FOCUS_NONE
	_save_btn.visible = false
	_save_btn.pressed.connect(save_music_data)
	bar.add_child(_save_btn)

	_bake_chip = PanelContainer.new()
	_bake_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.07)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	_bake_chip.add_theme_stylebox_override("panel", sb)
	_bake_label = Label.new()
	_bake_chip.add_child(_bake_label)
	bar.add_child(_bake_chip)

	_add_btn = Button.new()
	_add_btn.text = "Add track"
	_add_btn.focus_mode = Control.FOCUS_NONE
	_add_btn.pressed.connect(add_track)
	bar.add_child(_add_btn)
	_inspector_btn = Button.new()
	_inspector_btn.text = "Inspector"
	_inspector_btn.toggle_mode = true
	_inspector_btn.button_pressed = true
	_inspector_btn.focus_mode = Control.FOCUS_NONE
	_inspector_btn.tooltip_text = "Show or hide the track inspector."
	_inspector_btn.toggled.connect(func(on: bool):
		_inspector_pref = 1 if on else 0
		_relayout())
	bar.add_child(_inspector_btn)

func _head_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func _build_body() -> void:
	var s := _s()
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	_page.add_child(body)

	var main := VBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 6)
	body.add_child(main)

	_stage = Control.new()
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage.clip_contents = true
	_stage.custom_minimum_size.y = 210.0 * s
	_stage.resized.connect(_place_playhead)
	main.add_child(_stage)
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", int(4 * s))
	_stage.add_child(col)

	# Progression row: a gutter with the title and +, then the chips.
	var prog_row := HBoxContainer.new()
	prog_row.add_theme_constant_override("separation", 0)
	col.add_child(prog_row)
	var pg := HBoxContainer.new()
	_prog_gutter = pg
	prog_row.add_child(pg)
	var pl := Label.new()
	pl.text = "Progression"
	pl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pg.add_child(pl)
	_prog_lane = SynthProgressionLane.new()
	_prog_lane.timeline = timeline
	_prog_lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prog_lane.block_selected.connect(_select_block)
	prog_row.add_child(_prog_lane)

	# Ruler row.
	var ruler_row := HBoxContainer.new()
	ruler_row.add_theme_constant_override("separation", 0)
	col.add_child(ruler_row)
	var rg := Control.new()
	_ruler_gutter = rg
	ruler_row.add_child(rg)
	_ruler = SynthSongRuler.new()
	_ruler.timeline = timeline
	_ruler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ruler.seek_requested.connect(seek)
	ruler_row.add_child(_ruler)

	# Lanes. The scroll bar is hidden (the wheel still scrolls) so the lanes stay
	# exactly as wide as the rows above them.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", int(4 * s))
	scroll.add_child(inner)
	_lane_box = VBoxContainer.new()
	_lane_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lane_box.add_theme_constant_override("separation", int(4 * s))
	inner.add_child(_lane_box)
	_empty_label = Label.new()
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	inner.add_child(_empty_label)

	_playhead = SynthSongPlayhead.new()
	_playhead.timeline = timeline
	_playhead.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage.add_child(_playhead)

	_build_drawer(main)

	_inspector = SynthTrackInspector.new()
	_inspector.custom_minimum_size = Vector2(INSPECTOR_WIDTH * s, 0)
	_inspector.edited.connect(_on_inspector_edited)
	_inspector.pattern_open_requested.connect(func(): _open_pattern_of(_selected_index()))
	_inspector.patch_open_requested.connect(func():
		var i := _selected_index()
		if i >= 0 and tracks[i].patch != null:
			patch_requested.emit(tracks[i].patch))
	_inspector.remove_requested.connect(remove_selected_track)
	_inspector.match_requested.connect(func(): match_pattern_type(_selected_index()))
	body.add_child(_inspector)

func _build_drawer(parent: Control) -> void:
	var s := _s()
	_drawer = PanelContainer.new()
	parent.add_child(_drawer)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 4)
	_drawer.add_child(rows)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 4)
	rows.add_child(flow)
	_drawer_title = Label.new()
	_drawer_title.add_theme_font_size_override("font_size", 15)
	_drawer_title.custom_minimum_size.x = 150.0 * s
	flow.add_child(_drawer_title)

	var l_chord := _head_label("Chord")
	flow.add_child(l_chord)
	_blk_root = _note_menu()
	_blk_root.tooltip_text = "Chord root: MusicBlock.chord_root."
	_blk_root.item_selected.connect(func(i: int): _edit_block("Set chord root", &"chord_root", i))
	flow.add_child(_blk_root)
	_blk_quality = OptionButton.new()
	_blk_quality.focus_mode = Control.FOCUS_NONE
	_blk_quality.tooltip_text = "Chord quality: the chord_intervals a chord track plays. \"Custom\" is shown for intervals that match none of these; pick it to set the intervals yourself."
	_blk_quality.item_selected.connect(_on_quality_selected)
	flow.add_child(_blk_quality)
	var l_scale := _head_label("Scale")
	flow.add_child(l_scale)
	_blk_sroot = _note_menu()
	_blk_sroot.tooltip_text = "Scale root: MusicBlock.scale_root. Often the chord's root, but it can differ."
	_blk_sroot.item_selected.connect(func(i: int): _edit_block("Set scale root", &"scale_root", i))
	flow.add_child(_blk_sroot)
	_blk_scale = OptionButton.new()
	_blk_scale.focus_mode = Control.FOCUS_NONE
	_blk_scale.tooltip_text = "Scale: the scale_intervals a melody track plays. \"Custom\" is shown for intervals that match none of these; pick it to set the intervals yourself."
	_blk_scale.item_selected.connect(_on_scale_selected)
	flow.add_child(_blk_scale)
	var l_beats := _head_label("Beats")
	flow.add_child(l_beats)
	_blk_beats = SpinBox.new()
	_blk_beats.min_value = 1
	_blk_beats.max_value = 256
	_blk_beats.step = 1
	_blk_beats.custom_minimum_size.x = 84.0 * s
	_blk_beats.tooltip_text = "How long the block lasts: MusicBlock.duration_beats."
	_blk_beats.value_changed.connect(func(v: float): _edit_block("Set block length", &"duration_beats", int(v), true))
	flow.add_child(_blk_beats)

	_blk_left = _drawer_button("<", "Move the block one place earlier.", func(): _move_block(-1))
	flow.add_child(_blk_left)
	_blk_right = _drawer_button(">", "Move the block one place later.", func(): _move_block(1))
	flow.add_child(_blk_right)
	_blk_add = _drawer_button("Add block", "Add a block after this one, copied from it.", func(): add_block())
	flow.add_child(_blk_add)
	_blk_remove = _drawer_button("Remove", "Remove this block.", func(): remove_block())
	flow.add_child(_blk_remove)
	_drawer_labels = [l_chord, l_scale, l_beats]

	_chord_editor = SynthIntervalEditor.new()
	_chord_editor.setup("Chord tones", 2, s)
	_chord_editor.intervals_changed.connect(func(iv: PackedInt32Array): _edit_block("Set chord intervals", &"chord_intervals", iv))
	rows.add_child(_chord_editor)
	_scale_editor = SynthIntervalEditor.new()
	_scale_editor.setup("Scale notes", 1, s)
	_scale_editor.intervals_changed.connect(func(iv: PackedInt32Array): _edit_block("Set scale intervals", &"scale_intervals", iv))
	rows.add_child(_scale_editor)

func _drawer_button(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _note_menu() -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	for i in 12:
		o.add_item(SynthHarmony.NOTE_NAMES[i], i)
	return o

func _build_dialogs() -> void:
	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.filters = PackedStringArray(["*.tscn, *.scn ; Scene"])
	_dialog.size = Vector2i(720, 520)
	_dialog.file_selected.connect(func(p: String): set_scene(p))
	add_child(_dialog)

# Editor-theme icons when the editor theme is inherited; the plain text anywhere else.
func _apply_icons() -> void:
	if _blk_left == null:
		return
	for pr in [[_blk_left, "Back", "<"], [_blk_right, "Forward", ">"]]:
		var b: Button = pr[0]
		if has_theme_icon(pr[1], "EditorIcons"):
			b.icon = get_theme_icon(pr[1], "EditorIcons")
			b.text = ""
		else:
			b.icon = null
			b.text = pr[2]

func _relayout() -> void:
	var show: bool = _inspector_pref == 1 or (_inspector_pref == -1 and size.x >= INSPECTOR_AUTO_HIDE * _s())
	_inspector.visible = show
	_inspector_btn.set_pressed_no_signal(show)
	var g := _gutter()
	_prog_gutter.custom_minimum_size.x = g
	_ruler_gutter.custom_minimum_size.x = g
	for lane in _lanes:
		lane.set_gutter(g)
	_place_playhead.call_deferred()

# Width of the name column. Narrower in a narrow tab, so the timeline keeps room.
func _gutter() -> float:
	return (SynthTrackLane.GUTTER_NARROW if size.x < 640.0 * _s() else SynthTrackLane.GUTTER) * _s()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Use the tab's shared preview rig for Play. Call once the view is in the tree.
func bind_preview(p: SynthPreview) -> void:
	if _preview != null:
		if _preview.playing_changed.is_connected(_on_playing_changed):
			_preview.playing_changed.disconnect(_on_playing_changed)
		if _preview.music_data_changed.is_connected(_on_preview_data_changed):
			_preview.music_data_changed.disconnect(_on_preview_data_changed)
	_preview = p
	if p == null:
		return
	p.ensure_started()
	p.playing_changed.connect(_on_playing_changed)
	p.music_data_changed.connect(_on_preview_data_changed)
	_playhead.director = p.director
	if not _swing_read:
		_swing_read = true
		_swing = _project_swing()
		_swing_spin.set_value_no_signal(_swing)
	p.director.swing_amount = _swing
	_rebuild()

func get_preview() -> SynthPreview:
	return _preview

## Read [param path] (a music scene) and list its tracks; "" clears. The scene is
## edited through its live nodes when it is open in the editor.
## [param announce] false: do not tell the tab (it already knows).
func set_scene(path: String, announce: bool = true) -> void:
	scene_path = path
	_selected_block = -1
	selected_path = ""
	muted.clear()
	soloed.clear()
	_free_detached()
	_root = null
	live = false
	_sig = ""
	_announce_clear = announce and path == ""
	if announce:
		scene_changed.emit(path)
	refresh(true)

## Read the scene again if anything about it changed (or always, with
## [param force]): the open-in-editor state, its tracks' settings, the MusicData.
func refresh(force: bool = false) -> void:
	if not _built or not is_inside_tree():
		return
	var rebound := _resolve_root(force)
	var sig := _signature()
	if not force and not rebound and sig == _sig:
		return
	_sig = sig
	_rebuild()

## Open the scene in the editor's scene tabs (so its tracks become editable).
func open_scene_in_editor() -> void:
	var ei := _editor_interface()
	if ei == null or scene_path == "":
		return
	ei.call("open_scene_from_path", scene_path)
	refresh.call_deferred(true)

## The editor's active scene or open scenes changed (EditorPlugin.scene_changed /
## scene_closed): look again.
func editor_scenes_changed() -> void:
	if is_inside_tree():
		refresh.call_deferred()

## The song as the Pattern view wants it: the tracks as they are now, unsaved edits
## included. Null without a scene.
func make_context() -> SynthSongContext:
	if scene_path == "" or _root == null or not is_instance_valid(_root):
		return null
	return SynthSongContext.from_root(scene_path, _root, live)

## Give the keyboard focus to the view (so Space plays at once).
func focus_view() -> void:
	if is_visible_in_tree():
		grab_focus()

func get_lane(i: int) -> SynthTrackLane:
	return _lanes[i] if i >= 0 and i < _lanes.size() else null

func get_lanes() -> Array[SynthTrackLane]:
	return _lanes

func get_progression_lane() -> SynthProgressionLane:
	return _prog_lane

func get_ruler() -> SynthSongRuler:
	return _ruler

func get_playhead() -> SynthSongPlayhead:
	return _playhead

func get_inspector() -> SynthTrackInspector:
	return _inspector

func get_selected_block() -> int:
	return _selected_block

func get_cursor_beat() -> float:
	return _cursor_beat

## The block editor's widgets, for tests.
func get_drawer_controls() -> Dictionary:
	return {"chord_root": _blk_root, "quality": _blk_quality, "scale_root": _blk_sroot, "scale": _blk_scale,
			"chord_editor": _chord_editor, "scale_editor": _scale_editor, "beats": _blk_beats, "left": _blk_left, "right": _blk_right, "add": _blk_add, "remove": _blk_remove,
			"title": _drawer_title}

## The header's widgets, for tests.
func get_header_controls() -> Dictionary:
	return {"bpm": _bpm_spin, "swing": _swing_spin, "open": _open_btn, "state": _state_label, "bake": _bake_label,
			"data": _data_label, "save": _save_btn, "add": _add_btn}

func get_bake_chip_text() -> String:
	return _bake_label.text

func get_lane_summary() -> Array:
	var out: Array = []
	for i in tracks.size():
		var t := tracks[i]
		var clips := 0
		if t.pattern != null and t.pattern.length_beats > 0.0:
			clips = int(ceilf(timeline.span / t.pattern.length_beats - 0.0001))
		out.append({"name": String(t.name), "type": int(t.track_type), "channel": t.synth_channel,
				"pattern": t.pattern.resource_path.get_file() if t.pattern != null else "-", "clips": clips,
				"audible": is_audible(i)})
	return out

func get_selected_track() -> MusicTrack:
	var i := _selected_index()
	return tracks[i] if i >= 0 else null

## Can the tracks be edited? (The scene is open in the editor.)
func is_editable() -> bool:
	return live

## The MusicData the progression lane shows: what the preview plays.
func get_data() -> MusicData:
	return _display_data()

# ---------------------------------------------------------------------------
# Finding the scene
# ---------------------------------------------------------------------------

static func _editor_interface() -> Object:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		return Engine.get_singleton(&"EditorInterface")
	return null

func _find_open_root(path: String) -> Node:
	return SynthSongContext.find_open_root(path)

# Decide whether to hold the scene's live nodes or a detached copy. True when the
# thing being read was swapped for another.
func _resolve_root(force: bool) -> bool:
	if scene_path == "":
		var had := _root != null
		_free_detached()
		_root = null
		live = false
		return had
	var open := _find_open_root(scene_path)
	if open != null:
		if live and is_instance_valid(_root) and _root == open:
			return false
		_free_detached()
		_root = open
		live = true
		return true
	var mtime := FileAccess.get_modified_time(scene_path) if FileAccess.file_exists(scene_path) else 0
	if not live and _root != null and is_instance_valid(_root) and not force and mtime == _mtime:
		return false
	_free_detached()
	_root = null
	live = false
	_mtime = mtime
	var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed != null:
		_detached = packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
		_root = _detached
	return true

func _free_detached() -> void:
	if _detached != null and is_instance_valid(_detached):
		_detached.free()
	_detached = null

func _collect(node: Node, out: Array[MusicTrack]) -> void:
	if node is MusicTrack:
		out.append(node)
	for c in node.get_children():
		_collect(c, out)

func _track_path(t: MusicTrack) -> String:
	if not is_instance_valid(t) or _root == null or not is_instance_valid(_root):
		return ""
	return str(_root.get_path_to(t)) if t != _root else String(t.name)

# Everything the view draws, as a string: it changes when anything does.
func _signature() -> String:
	var s := "%s|%s|%s|" % [scene_path, live, _root.get_instance_id() if _root != null and is_instance_valid(_root) else 0]
	if _root != null and is_instance_valid(_root):
		var list: Array[MusicTrack] = []
		_collect(_root, list)
		for t in list:
			s += "%s,%d,%d,%d,%d,%.3f,%s,%d,%s,%s,%s;" % [t.name, t.track_type, t.synth_channel, t.base_octave, t.swap_mode,
					t.pan, t.output_bus, t.effects.size(), _res_sig(t.pattern), _res_sig(t.patch), t.get_index()]
		var d := SynthSongContext.find_music_data(_root)
		s += "D%s" % (str(d.get_instance_id()) if d != null else "-")
	s += "|" + SynthHarmony.fingerprint(_display_data())
	return s

# A pattern's identity plus enough of its content to notice an edit.
func _res_sig(r: Resource) -> String:
	if r == null:
		return "-"
	var s := str(r.get_instance_id())
	var p := r as MusicPattern
	if p != null:
		var acc := 0.0
		for n in p.notes:
			acc += n.beat * 7.0 + n.duration * 3.0 + float(n.index) * 13.0 + float(n.octave) * 17.0
		s += ":%s:%d:%s:%d" % [p.length_beats, p.notes.size(), acc, int(p.editor_track_type)]
	return s

func _on_poll() -> void:
	if is_visible_in_tree():
		refresh()

func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		refresh(true)

func _on_history_changed() -> void:
	if _history_queued:
		return
	_history_queued = true
	_history_refresh.call_deferred()

func _history_refresh() -> void:
	_history_queued = false
	if is_visible_in_tree():
		refresh()

func _on_preview_data_changed(_d: MusicData) -> void:
	refresh(true)

# ---------------------------------------------------------------------------
# Building what is shown
# ---------------------------------------------------------------------------

# The progression the lanes sit over: what the preview plays.
func _display_data() -> MusicData:
	if _preview != null:
		return _preview.get_effective_music_data()
	return scene_data if scene_data != null and not scene_data.blocks.is_empty() else SynthPreview.make_default_music_data()

func _rebuild() -> void:
	if not _built:
		return
	tracks.clear()
	scene_data = null
	if _root != null and is_instance_valid(_root):
		_collect(_root, tracks)
		scene_data = SynthSongContext.find_music_data(_root)
	_note_data()
	_announce_data_change()

	timeline.data = _display_data()
	var longest := 0.0
	for t in tracks:
		if t.pattern != null:
			longest = maxf(longest, t.pattern.length_beats)
	timeline.span = SynthTimeline.choose_span(timeline.progression_beats(), longest)

	if _selected_index() < 0:
		selected_path = _track_path(tracks[0]) if not tracks.is_empty() else ""

	_header_refresh()
	_rebuild_lanes()
	_prog_lane.selected = clampi(_selected_block, -1, timeline.data.blocks.size() - 1) if timeline.data != null else -1
	_selected_block = _prog_lane.selected
	_prog_lane.queue_redraw()
	_ruler.queue_redraw()
	_sync_drawer()
	_refresh_bake()
	_refresh_inspector()
	_place_playhead.call_deferred()
	_sync_song_playback()
	_announce_context()

# Tell the tab what the song looks like now, once per change (not per rebuild).
func _announce_context() -> void:
	if scene_path == "":
		if _announce_clear:
			_announce_clear = false
			_ctx_sig = ""
			song_context_changed.emit(null)
		return
	if _sig == _ctx_sig:
		return
	_ctx_sig = _sig
	if _root != null and is_instance_valid(_root):
		song_context_changed.emit(SynthSongContext.from_root(scene_path, _root, live))
	else:
		song_context_changed.emit(null)

func _rebuild_lanes() -> void:
	for c in _lane_box.get_children():
		_lane_box.remove_child(c)
		c.queue_free()
	_lanes.clear()
	for i in tracks.size():
		var t := tracks[i]
		var lane := SynthTrackLane.new()
		_lane_box.add_child(lane)
		var color: Color = SynthPatternView.FAINT_COLORS[i % SynthPatternView.FAINT_COLORS.size()]
		lane.setup(String(t.name), _lane_sub(t), "%s\n%s" % [_track_path(t), _lane_tip(t)], color)
		lane.set_warning(SynthSongContext.clash_text(t.pattern, int(t.track_type)))
		lane.set_gutter(_gutter())
		lane.clips.timeline = timeline
		lane.clips.pattern = t.pattern
		lane.clips.track_type = int(t.track_type)
		lane.clips.color = color
		lane.clips.clip_name = _res_name(t.pattern, "(inline pattern)")
		lane.clips.rebuild()
		var path := _track_path(t)
		lane.selected.connect(_select_path.bind(path))
		lane.clip_activated.connect(func(): _open_pattern_of(_index_of_path(path)))
		lane.mute_toggled.connect(func(on: bool): _set_mute(path, on))
		lane.solo_toggled.connect(func(on: bool): _set_solo(path, on))
		lane.set_selected(path == selected_path)
		_lanes.append(lane)
	_apply_audibility(false)
	_empty_label.visible = tracks.is_empty()
	if scene_path == "":
		_empty_label.text = "Pick a music scene to see its tracks as lanes."
	elif _root == null:
		_empty_label.text = "Could not read " + scene_path
	else:
		_empty_label.text = "This scene has no MusicTrack nodes."

func _lane_sub(t: MusicTrack) -> String:
	var type_name: String = SynthTrackInspector.TYPE_NAMES[clampi(int(t.track_type), 0, 2)]
	return "%s  ch%d%s" % [type_name, t.synth_channel, "" if t.track_type == MusicTrack.TrackType.DRUM else "  oct %d" % t.base_octave]

func _lane_tip(t: MusicTrack) -> String:
	return "Patch: %s\nPattern: %s" % [_res_name(t.patch, "none"), _res_name(t.pattern, "none")]

static func _res_name(res: Resource, fallback: String) -> String:
	if res == null:
		return fallback
	if res.resource_path != "" and not "::" in res.resource_path:
		return res.resource_path.get_file()
	return "(inline)"

func _header_refresh() -> void:
	_path_label.text = scene_path.get_file() if scene_path != "" else "(none)"
	_path_label.tooltip_text = scene_path
	if scene_path == "":
		_state_label.text = ""
		_open_btn.visible = false
	elif live:
		_state_label.text = "Open in the editor: edits go to its scene tab"
		_state_label.add_theme_color_override("font_color", SynthRackStyle.good(self))
		_state_label.tooltip_text = "Track edits are undoable in the editor and mark the scene unsaved. Ctrl+S saves it."
		_open_btn.visible = true
		_open_btn.text = "Open scene"
		_open_btn.tooltip_text = "Switch to the scene's tab."
	else:
		_state_label.text = "Read-only: the scene is not open"
		_state_label.add_theme_color_override("font_color", SynthRackStyle.warn(self))
		_state_label.tooltip_text = "Tracks are edited through the open scene, so that undo and Ctrl+S work. Open it to edit them."
		_open_btn.visible = true
		_open_btn.text = "Open scene to edit"
		_open_btn.tooltip_text = "Open the scene in the editor."
	_open_btn.disabled = _editor_interface() == null
	_add_btn.visible = live
	_add_btn.tooltip_text = "Add a MusicTrack to the scene (undoable)."
	var d := _display_data()
	var editable := _data_editable()
	_bpm_spin.set_value_no_signal(d.bpm)
	_bpm_spin.editable = editable
	_swing_spin.set_value_no_signal(_swing)
	if _preview != null and _preview.is_using_default_data():
		_data_label.text = "(default)"
		_data_label.tooltip_text = "No MusicData is chosen, so the preview runs against the built-in default. Pick a scene that has one, or Choose one in the top bar."
	else:
		var p := _data_path(d)
		_data_label.text = p.get_file() if p != "" else "(inline)"
		_data_label.tooltip_text = p if p != "" else "The MusicData is stored inside the scene."
	_save_btn.visible = _edited_flag and _data_path(d) != ""
	_save_btn.tooltip_text = "Write %s." % _data_path(d)

func _refresh_inspector() -> void:
	var i := _selected_index()
	if i < 0:
		_inspector.show_none("Select a track." if not tracks.is_empty() else "No tracks.")
		return
	var t := tracks[i]
	var can_remove := live and t != _root and t.owner == _root and t.get_child_count() == 0
	var tip := "Remove this track from the scene (undoable)."
	if live and not can_remove:
		tip = "Only a track that belongs directly to this scene and has no children can be removed here."
	var bake := ""
	if t.patch != null:
		var info: SynthBakeInfo.Info = _bake_infos.get(SynthSongContext.path_of(t.patch))
		if info != null:
			bake = "Bake: %s." % info.chip_text().to_lower().replace("bake ", "")
	var match_tip := "The scene is not open in the editor, so its tracks are read-only. Use \"Open scene to edit\"."
	if live and t.pattern != null:
		match_tip = "Set this track's type to %s, like its pattern (undoable)." % SynthPitchMap.type_name(int(t.pattern.editor_track_type))
	_inspector.show_track(t, {
		"editable": live, "path": _track_path(t), "can_remove": can_remove, "remove_tip": tip, "bake": bake,
		"clash": SynthSongContext.clash_text(t.pattern, int(t.track_type)), "match_tip": match_tip,
		"banner": "" if live else "Read-only: the scene is not open in the editor. Use \"Open scene to edit\".",
	})

# ---------------------------------------------------------------------------
# Bake chip
# ---------------------------------------------------------------------------

func _refresh_bake() -> void:
	_bake_infos.clear()
	var stale := PackedStringArray()
	var none := PackedStringArray()
	var ok := 0
	var seen := {}
	for t in tracks:
		var p := t.patch
		var path := SynthSongContext.path_of(p)
		if p == null or path == "" or seen.has(path):
			continue
		seen[path] = true
		var info := SynthBakeInfo.inspect(p, path, index)
		_bake_infos[path] = info
		match info.state:
			SynthBakeInfo.State.STALE:
				stale.append(path.get_file())
			SynthBakeInfo.State.NONE:
				none.append(path.get_file())
			_:
				ok += 1
	var text := ""
	var col := SynthRackStyle.dim(self)
	var tip := PackedStringArray()
	if seen.is_empty():
		text = "No patches"
		tip.append("None of the tracks uses a saved patch.")
	elif not stale.is_empty():
		text = "%d patch%s %s a re-bake" % [stale.size(), "" if stale.size() == 1 else "es", "needs" if stale.size() == 1 else "need"]
		col = SynthRackStyle.warn(self)
	elif not none.is_empty():
		text = "%d patch%s not baked" % [none.size(), "" if none.size() == 1 else "es"]
	else:
		text = "All baked"
		col = SynthRackStyle.good(self)
	if not stale.is_empty():
		tip.append("Needs a re-bake: " + ", ".join(stale))
	if not none.is_empty():
		tip.append("No baked set: " + ", ".join(none))
	if ok > 0:
		tip.append("%d up to date." % ok)
	if not stale.is_empty():
		tip.append("Baking is done by your project's bake tool, not from here (see the Sound view's chip).")
	_bake_label.text = text
	_bake_label.add_theme_color_override("font_color", col)
	_bake_chip.tooltip_text = "\n".join(tip)

# ---------------------------------------------------------------------------
# Selecting
# ---------------------------------------------------------------------------

func _selected_index() -> int:
	return _index_of_path(selected_path)

func _index_of_path(path: String) -> int:
	if _root == null or not is_instance_valid(_root):
		return -1
	for i in tracks.size():
		if _track_path(tracks[i]) == path:
			return i
	return -1

func _select_path(path: String) -> void:
	selected_path = path
	for i in _lanes.size():
		_lanes[i].set_selected(_track_path(tracks[i]) == path)
	_refresh_inspector()

## Select lane [param i].
func select_track(i: int) -> void:
	if i >= 0 and i < tracks.size():
		_select_path(_track_path(tracks[i]))

func _open_pattern_of(i: int) -> void:
	if i < 0 or i >= tracks.size() or tracks[i].pattern == null:
		return
	pattern_requested.emit(tracks[i].pattern, tracks[i].patch)

# ---------------------------------------------------------------------------
# Mute and solo
# ---------------------------------------------------------------------------

func is_audible(i: int) -> bool:
	if i < 0 or i >= tracks.size():
		return false
	var path := _track_path(tracks[i])
	if not soloed.is_empty():
		return soloed.has(path)
	return not muted.has(path)

func _set_mute(path: String, on: bool) -> void:
	if on:
		muted[path] = true
	else:
		muted.erase(path)
	_apply_audibility(true)

func _set_solo(path: String, on: bool) -> void:
	if on:
		soloed[path] = true
	else:
		soloed.erase(path)
	_apply_audibility(true)

## Mute or unmute lane [param i], as its M button does.
func set_muted(i: int, on: bool) -> void:
	if i >= 0 and i < tracks.size():
		_set_mute(_track_path(tracks[i]), on)

## Solo or unsolo lane [param i], as its S button does.
func set_soloed(i: int, on: bool) -> void:
	if i >= 0 and i < tracks.size():
		_set_solo(_track_path(tracks[i]), on)

func _apply_audibility(push: bool) -> void:
	for i in _lanes.size():
		var path := _track_path(tracks[i])
		var a := is_audible(i)
		_lanes[i].set_state(muted.has(path), soloed.has(path), a)
		if push and _preview != null and _preview.is_song_on():
			_preview.set_song_lane_audible(i, a)

# ---------------------------------------------------------------------------
# Playback
# ---------------------------------------------------------------------------

func _lane_spec(i: int) -> Dictionary:
	var t := tracks[i]
	return {"pattern": t.pattern, "type": int(t.track_type), "patch": t.patch, "channel": t.synth_channel,
			"base_octave": t.base_octave, "pan": t.pan, "audible": is_audible(i)}

## Play every lane together, from the playhead.
func start_song() -> void:
	if _preview == null:
		return
	_preview.ensure_started()
	_preview.director.swing_amount = _swing
	var specs: Array = []
	for i in tracks.size():
		specs.append(_lane_spec(i))
	_preview.play_song(specs, _cursor_beat)
	_playing_specs = specs.map(_spec_key)
	_song_started = true
	_playhead.director = _preview.director

func stop_song() -> void:
	if _preview != null:
		_preview.stop()

func is_song_playing() -> bool:
	return _preview != null and _preview.is_song_on() and _preview.is_playing()

func toggle_song() -> void:
	if is_song_playing():
		stop_song()
	else:
		start_song()

# A track changed while the song plays: carry the change into the running song.
func _sync_song_playback() -> void:
	if _preview == null or not _preview.is_song_on() or not _preview.is_playing():
		return
	if _preview.song_tracks.size() != tracks.size():
		var at := _preview.director.get_total_beats()
		_cursor_beat = fposmod(at, timeline.span)
		start_song()
		return
	for i in tracks.size():
		var spec := _lane_spec(i)
		var key := _spec_key(spec)
		if i >= _playing_specs.size() or _playing_specs[i] != key:
			_preview.update_song_lane(i, spec)
			if i < _playing_specs.size():
				_playing_specs[i] = key

# A lane's spec without mute / solo, which the preview is told about separately.
static func _spec_key(spec: Dictionary) -> Dictionary:
	var k := spec.duplicate()
	k.erase("audible")
	return k

func _on_playing_changed(playing: bool) -> void:
	if not playing and _song_started:
		_song_started = false
		# The cursor goes back to where the song started (or was last put).
		if _preview.director != null:
			_preview.director.seek(_cursor_beat)
	_playhead.queue_redraw()

## Move the playhead to [param beat] (the timeline's, not the song's total).
func seek(beat: float) -> void:
	_cursor_beat = clampf(beat, 0.0, timeline.span)
	if _preview != null and _preview.director != null:
		_preview.director.seek(_cursor_beat)
	_playhead.queue_redraw()

func _place_playhead() -> void:
	if _prog_lane == null or _stage == null or not is_instance_valid(_prog_lane):
		return
	_playhead.area_x = _prog_lane.global_position.x - _stage.global_position.x
	_playhead.area_w = _prog_lane.size.x
	_playhead.queue_redraw()

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or not is_visible_in_tree():
		return
	if k.keycode == KEY_SPACE and not (k.ctrl_pressed or k.alt_pressed or k.meta_pressed or k.shift_pressed) and _view_has_focus():
		toggle_song()
		get_viewport().set_input_as_handled()

func _view_has_focus() -> bool:
	var fo := get_viewport().gui_get_focus_owner()
	if fo == null or not (fo == self or is_ancestor_of(fo)):
		return false
	return not (fo is LineEdit or fo is TextEdit)

# A click on the view's empty space focuses the view (and so Space works).
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		grab_focus()

# The Music autoload's swing, so the preview starts out feeling like the game.
static func _project_swing() -> float:
	var entry := str(ProjectSettings.get_setting("autoload/Music", ""))
	entry = entry.trim_prefix("*")
	if entry == "" or not ResourceLoader.exists(entry):
		return 0.0
	var packed := ResourceLoader.load(entry) as PackedScene
	if packed == null:
		return 0.0
	var node := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if node == null:
		return 0.0
	var v: Variant = node.get("swing_amount")
	node.free()
	return float(v) if v != null else 0.0

func _on_swing_changed(v: float) -> void:
	_swing = v
	if _preview != null and _preview.director != null:
		_preview.director.swing_amount = v

# ---------------------------------------------------------------------------
# Editing tracks (live nodes of the open scene)
# ---------------------------------------------------------------------------

func _on_inspector_edited(prop: StringName, value: Variant, merge: bool) -> void:
	set_track_property(_selected_index(), prop, value, merge)

## Set [param prop] of lane [param i]'s MusicTrack to [param value], as one undo
## action on the scene. False if the scene is not open (tracks are read-only).
func set_track_property(i: int, prop: StringName, value: Variant, merge: bool = false) -> bool:
	if not live or i < 0 or i >= tracks.size():
		_refresh_inspector()   # a read-only panel snaps back to what the node holds
		return false
	var t := tracks[i]
	if t.get(prop) == value:
		return true
	_edit.set_properties("Set %s" % prop, t, [[t, prop, value]], merge)
	refresh(true)
	return true

## Set lane [param i]'s track type to the one its pattern is marked with, as one
## undo action on the scene (the inspector's Type menu does the same). False if
## the scene is not open or there is nothing to match.
func match_pattern_type(i: int) -> bool:
	if i < 0 or i >= tracks.size() or not SynthSongContext.clash(tracks[i].pattern, int(tracks[i].track_type)):
		return false
	return set_track_property(i, &"track_type", int(tracks[i].pattern.editor_track_type))

## Set the type of the tracks named [param names] (paths from the scene's root, as
## in SynthSongContext.tracks) of the scene at [param scene] to [param type], as one
## undo action. For the Pattern view, whose tracks may be in any scene. False if
## that scene is not open in the editor or none of the tracks is there.
func match_track_types(scene: String, names: Array, type: int) -> bool:
	var root := _find_open_root(scene)
	if root == null:
		return false
	var changes: Array = []
	var found := false
	for n in names:
		var t := SynthSongContext.node_for(root, String(n)) as MusicTrack
		if t == null:
			continue
		found = true
		if int(t.track_type) != type:
			changes.append([t, &"track_type", type])
	if not changes.is_empty():
		_edit.set_properties("Set track_type", root, changes)
		if scene == scene_path:
			refresh(true)
	return found

## Add a MusicTrack to the scene (next to the others), as one undo action.
func add_track() -> void:
	if not live or _root == null:
		return
	var parent: Node = tracks[0].get_parent() if not tracks.is_empty() else _root
	var t := MusicTrack.new()
	t.name = "NewTrack"
	var used := {}
	for o in tracks:
		used[o.synth_channel] = true
	var ch := 0
	while used.has(ch) and ch < 15:
		ch += 1
	t.synth_channel = ch
	var script := t.get_script() as Script
	if script != null and script.resource_path != "":
		var uid := ResourceLoader.get_resource_uid(script.resource_path)
		if uid != ResourceUID.INVALID_ID:
			t.set_meta("_custom_type_script", ResourceUID.id_to_text(uid))
	_edit.add_node("Add MusicTrack", _root, parent, t)
	selected_path = _track_path(t)
	refresh(true)

## Remove the selected track from the scene, as one undo action.
func remove_selected_track() -> void:
	var i := _selected_index()
	if not live or i < 0:
		return
	var t := tracks[i]
	if t == _root or t.owner != _root or t.get_child_count() > 0:
		return
	selected_path = ""
	_edit.remove_node("Remove MusicTrack", _root, t)
	refresh(true)

# ---------------------------------------------------------------------------
# Editing the progression (the MusicData)
# ---------------------------------------------------------------------------

func _is_builtin(res: Resource) -> bool:
	return res != null and "::" in res.resource_path

static func _data_path(d: MusicData) -> String:
	if d == null or d.resource_path == "" or "::" in d.resource_path:
		return ""
	return d.resource_path

# A real MusicData of the scene or the project, not the built-in fallback; and, if
# it lives inside the scene, only while the scene is open.
func _data_editable() -> bool:
	if _preview == null or _preview.is_using_default_data():
		return false
	var d := _display_data()
	if _is_builtin(d) and not live:
		return false
	return true

# Track which MusicData the "edited" flag speaks for.
func _note_data() -> void:
	var d := _display_data()
	if d != _clean_data:
		_set_edited_flag(false)
		_clean_data = d
		_clean_fp = SynthHarmony.fingerprint(d)
		return
	_set_edited_flag(SynthHarmony.fingerprint(d) != _clean_fp)

# The tab's top bar shows the tempo and chords too: tell it when they changed, by
# an edit here or one made elsewhere (Ctrl+Z).
func _announce_data_change() -> void:
	var key := "%s|%s" % [_display_data().get_instance_id() if _display_data() != null else 0, SynthHarmony.fingerprint(_display_data())]
	if key == _data_key:
		return
	var first := _data_key == ""
	_data_key = key
	if not first:
		music_data_edited.emit()

func _set_edited_flag(dirty: bool) -> void:
	if dirty == _edited_flag:
		return
	_edited_flag = dirty
	var ei := _editor_interface()
	var target: MusicData = _clean_data
	if ei != null and target != null:
		ei.call("set_object_edited", target, dirty)

func is_data_dirty() -> bool:
	return _edited_flag

## Write the MusicData back to its file.
func save_music_data() -> bool:
	var d := _display_data()
	var path := _data_path(d)
	if path == "":
		return false
	var err := ResourceSaver.save(d, path)
	if err != OK:
		push_error("[SynthTrackView] Could not save %s (err=%d)" % [path, err])
		return false
	_clean_fp = SynthHarmony.fingerprint(d)
	_clean_data = d
	_set_edited_flag(false)
	var ei := _editor_interface()
	if ei != null:
		var fs: Object = ei.call("get_resource_filesystem")
		fs.call("update_file", path)
	_header_refresh()
	return true

func _on_bpm_changed(v: float) -> void:
	set_bpm(v, true)

## Set the song's tempo (MusicData.bpm), as one undo action.
func set_bpm(v: float, merge: bool = false) -> void:
	if not _data_editable():
		return
	var d := _display_data()
	if is_equal_approx(d.bpm, v):
		return
	_edit.set_properties("Set BPM", d, [[d, &"bpm", v]], merge, [d])
	_after_data_edit()

func _select_block(i: int) -> void:
	_selected_block = i
	_open_chord_custom = null
	_open_scale_custom = null
	_prog_lane.selected = i
	_sync_drawer()

## Select block [param i] for editing, as clicking its chip does.
func select_block(i: int) -> void:
	var d := _display_data()
	if d != null and i >= 0 and i < d.blocks.size():
		_select_block(i)

func _sync_drawer() -> void:
	var d := _display_data()
	var i := _selected_block
	var has_block := d != null and i >= 0 and i < d.blocks.size()
	var editable := _data_editable()
	var why := "" if editable else "The preview is on the built-in default, or the MusicData lives inside a scene that is not open. Pick a scene that has a MusicData to edit it."
	_drawer.tooltip_text = why
	if not has_block:
		_drawer_title.text = "Click a chord above to edit it." if d != null and not d.blocks.is_empty() else "No blocks."
		for c in [_blk_root, _blk_quality, _blk_sroot, _blk_scale, _blk_beats, _blk_left, _blk_right, _blk_remove] + _drawer_labels:
			c.visible = false
		_chord_editor.visible = false
		_scale_editor.visible = false
		_blk_add.visible = editable
		_blk_add.disabled = false
		_blk_add.tooltip_text = "Add a block at the end."
		return
	for c in [_blk_root, _blk_quality, _blk_sroot, _blk_scale, _blk_beats, _blk_left, _blk_right, _blk_remove, _blk_add] + _drawer_labels:
		c.visible = true
	_blk_add.tooltip_text = "Add a block after this one, copied from it."
	var b: MusicBlock = d.blocks[i]
	_drawer_title.text = "Block %d of %d: %s" % [i + 1, d.blocks.size(), SynthHarmony.chord_name(b)]
	_blk_root.select(posmod(b.chord_root, 12))
	_blk_sroot.select(posmod(b.scale_root, 12))
	_blk_quality.clear()
	for e in SynthHarmony.chord_table():
		_blk_quality.add_item(e[1])
	var qi := SynthHarmony.chord_index(b.chord_intervals)
	var chord_custom := qi < 0 or _open_chord_custom == b
	if not chord_custom:
		_open_chord_custom = null
	# The last item is always the custom one: "Custom..." while a preset is set.
	_blk_quality.add_item("Custom (%s)" % SynthHarmony.intervals_text(b.chord_intervals) if qi < 0 else "Custom...")
	_blk_quality.select(_blk_quality.item_count - 1 if chord_custom else qi)
	_blk_scale.clear()
	for e in SynthHarmony.scale_table():
		_blk_scale.add_item(e[0])
	var si := SynthHarmony.scale_index(b.scale_intervals)
	var scale_custom := si < 0 or _open_scale_custom == b
	if not scale_custom:
		_open_scale_custom = null
	_blk_scale.add_item("Custom (%s)" % SynthHarmony.intervals_text(b.scale_intervals) if si < 0 else "Custom...")
	_blk_scale.select(_blk_scale.item_count - 1 if scale_custom else si)
	_chord_editor.visible = chord_custom
	_chord_editor.set_root(b.chord_root)
	_chord_editor.set_intervals(b.chord_intervals)
	_chord_editor.set_editable(editable)
	_scale_editor.visible = scale_custom
	_scale_editor.set_root(b.scale_root)
	_scale_editor.set_intervals(b.scale_intervals)
	_scale_editor.set_editable(editable)
	_blk_beats.set_value_no_signal(b.duration_beats)
	for c in [_blk_root, _blk_quality, _blk_sroot, _blk_scale, _blk_add]:
		c.disabled = not editable
	_blk_beats.editable = editable
	_blk_left.disabled = not editable or i == 0
	_blk_right.disabled = not editable or i == d.blocks.size() - 1
	_blk_remove.disabled = not editable or d.blocks.size() <= 1

func _edit_block(label: String, prop: StringName, value: Variant, merge: bool = false) -> void:
	var d := _display_data()
	if not _data_editable() or _selected_block < 0 or _selected_block >= d.blocks.size():
		return
	var b: MusicBlock = d.blocks[_selected_block]
	if b.get(prop) == value:
		return
	_edit.set_properties(label, d, [[b, prop, value]], merge, [d])
	_after_data_edit()

## Set a property of block [param i] (chord_root, chord_intervals, scale_root,
## scale_intervals, duration_beats), as the drawer does.
func set_block_property(i: int, prop: StringName, value: Variant) -> bool:
	if not _data_editable():
		return false
	var d := _display_data()
	if i < 0 or i >= d.blocks.size():
		return false
	var saved := _selected_block
	_selected_block = i
	var labels := {&"chord_root": "Set chord root", &"chord_intervals": "Set chord quality",
			&"scale_root": "Set scale root", &"scale_intervals": "Set scale", &"duration_beats": "Set block length"}
	_edit_block(labels.get(prop, "Set block"), prop, value)
	_selected_block = saved
	return true

# A preset sets the block's intervals; "Custom" changes nothing by itself: it opens
# the chips and text field, which start from the block's current intervals.
func _on_quality_selected(i: int) -> void:
	var table := SynthHarmony.chord_table()
	var d := _display_data()
	var b: MusicBlock = d.blocks[_selected_block] if d != null and _selected_block >= 0 and _selected_block < d.blocks.size() else null
	_open_chord_custom = null
	if i < table.size():
		_edit_block("Set chord quality", &"chord_intervals", PackedInt32Array(table[i][2]))
	elif b != null and _data_editable():
		_open_chord_custom = b
	_sync_drawer()

func _on_scale_selected(i: int) -> void:
	var table := SynthHarmony.scale_table()
	var d := _display_data()
	var b: MusicBlock = d.blocks[_selected_block] if d != null and _selected_block >= 0 and _selected_block < d.blocks.size() else null
	_open_scale_custom = null
	if i < table.size():
		_edit_block("Set scale", &"scale_intervals", PackedInt32Array(table[i][1]))
	elif b != null and _data_editable():
		_open_scale_custom = b
	_sync_drawer()

func _move_block(dir: int) -> void:
	var d := _display_data()
	var i := _selected_block
	var j := i + dir
	if not _data_editable() or i < 0 or j < 0 or j >= d.blocks.size():
		return
	var arr: Array[MusicBlock] = d.blocks.duplicate()
	var tmp := arr[i]
	arr[i] = arr[j]
	arr[j] = tmp
	_set_blocks("Move block", arr, j)

## Add a block after the selected one (or at the end), copied from it, as one
## undo action.
func add_block() -> void:
	var d := _display_data()
	if not _data_editable():
		return
	var at := d.blocks.size() if _selected_block < 0 else _selected_block + 1
	var nb := MusicBlock.new()
	var src: MusicBlock = d.blocks[clampi(at - 1, 0, d.blocks.size() - 1)] if not d.blocks.is_empty() else null
	if src != null:
		nb.chord_root = src.chord_root
		nb.chord_intervals = src.chord_intervals.duplicate()
		nb.scale_root = src.scale_root
		nb.scale_intervals = src.scale_intervals.duplicate()
		nb.duration_beats = src.duration_beats
	var arr: Array[MusicBlock] = d.blocks.duplicate()
	arr.insert(at, nb)
	_set_blocks("Add block", arr, at)

## Remove the selected block, as one undo action. The last block stays.
func remove_block() -> void:
	var d := _display_data()
	var i := _selected_block
	if not _data_editable() or i < 0 or i >= d.blocks.size() or d.blocks.size() <= 1:
		return
	var arr: Array[MusicBlock] = d.blocks.duplicate()
	arr.remove_at(i)
	_set_blocks("Remove block", arr, mini(i, arr.size() - 1))

func _set_blocks(label: String, arr: Array[MusicBlock], select: int) -> void:
	var d := _display_data()
	_edit.set_properties(label, d, [[d, &"blocks", arr]], false, [d])
	_selected_block = select
	_after_data_edit()

func _after_data_edit() -> void:
	if _preview != null:
		_preview.progression_edited()
	_sig = ""
	refresh(true)
