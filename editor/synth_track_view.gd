@tool
class_name SynthTrackView
extends VBoxContainer

# The Synth tab's Track view: a placeholder. It lists the MusicTracks found in a
# music scene (a .tscn the author picks), read-only: name, type, pattern, patch,
# channel, octave. The song-lanes editor over the progression replaces it.
#
# The scene is only read, never edited or added to a tree: it is instantiated
# with edit state disabled, its nodes' exported properties are read, and the
# whole thing is freed again. No _ready, no autoplay, no audio.

## The picked scene's MusicDataPlayer holds MusicData the author may want as the
## preview progression; the view offers it, the tab decides.
signal music_data_offered(data: MusicData)

const COLUMNS := ["Track", "Type", "Pattern", "Patch", "Channel", "Octave"]
const TYPE_NAMES := ["Chord", "Melody", "Drum"]

var scene_path: String = ""

var _path_label: Label
var _status_label: Label
var _use_data_btn: Button
var _tree: Tree
var _dialog: FileDialog
var _scene_data: MusicData

func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_build_ui()
	_show_rows([], "Pick a music scene to list its tracks.")

func _build_ui() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	var lbl := Label.new()
	lbl.text = "Music scene:"
	row.add_child(lbl)

	var pick := Button.new()
	pick.text = "Choose..."
	pick.tooltip_text = "Pick a .tscn that holds MusicTrack nodes (for example a level's music scene)."
	pick.pressed.connect(func(): _dialog.popup_centered())
	row.add_child(pick)

	var reload := Button.new()
	reload.text = "Reload"
	reload.tooltip_text = "Read the scene again."
	reload.pressed.connect(func(): set_scene(scene_path))
	row.add_child(reload)

	_path_label = Label.new()
	_path_label.text = "(none)"
	_path_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_path_label.custom_minimum_size = Vector2(80, 0)
	row.add_child(_path_label)

	_use_data_btn = Button.new()
	_use_data_btn.text = "Preview with this scene's MusicData"
	_use_data_btn.tooltip_text = "Use the scene's MusicDataPlayer progression as the tab's preview MusicData."
	_use_data_btn.disabled = true
	_use_data_btn.pressed.connect(func(): music_data_offered.emit(_scene_data))
	row.add_child(_use_data_btn)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = COLUMNS.size()
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	for i in COLUMNS.size():
		_tree.set_column_title(i, COLUMNS[i])
		_tree.set_column_expand(i, i != 4 and i != 5)
	_tree.set_column_custom_minimum_width(0, 140)
	_tree.set_column_custom_minimum_width(1, 80)
	_tree.set_column_custom_minimum_width(4, 70)
	_tree.set_column_custom_minimum_width(5, 70)
	_tree.set_column_expand_ratio(2, 2)
	_tree.set_column_expand_ratio(3, 2)
	add_child(_tree)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	add_child(_status_label)

	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.filters = PackedStringArray(["*.tscn, *.scn ; Scene"])
	_dialog.size = Vector2i(720, 520)
	_dialog.file_selected.connect(set_scene)
	add_child(_dialog)

## Read [param path] and list its MusicTracks. An empty path clears the list.
func set_scene(path: String) -> void:
	scene_path = path
	_scene_data = null
	_use_data_btn.disabled = true
	_path_label.text = path if path != "" else "(none)"
	_path_label.tooltip_text = path
	if path == "":
		_show_rows([], "Pick a music scene to list its tracks.")
		return
	var packed := load(path) as PackedScene
	if packed == null:
		_show_rows([], "Not a scene: " + path)
		return
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if root == null:
		_show_rows([], "Could not read " + path)
		return
	var rows: Array = []
	_collect(root, root, rows)
	_scene_data = _find_music_data(root)
	root.free()
	_use_data_btn.disabled = _scene_data == null
	var note := ""
	if _scene_data != null:
		note = "  |  MusicDataPlayer: %s, %.0f BPM, %d block(s)" % [
			_res_name(_scene_data, "(inline)"), _scene_data.bpm, _scene_data.blocks.size()]
	_show_rows(rows, "%d track(s)%s" % [rows.size(), note])

func _collect(node: Node, root: Node, out: Array) -> void:
	if node is MusicTrack:
		var t := node as MusicTrack
		var pat: MusicPattern = t.pattern
		var pt: SynthPatch = t.patch
		out.append({
			"name": str(root.get_path_to(node)) if node != root else node.name,
			"type": TYPE_NAMES[t.track_type] if t.track_type >= 0 and t.track_type < TYPE_NAMES.size() else str(t.track_type),
			"pattern": _res_name(pat, "-"),
			"patch": _patch_name(pt),
			"channel": t.synth_channel,
			"octave": t.base_octave,
		})
	for c in node.get_children():
		_collect(c, root, out)

# The scene's MusicDataPlayer, if any. It may be a placeholder instance, which
# still answers get() for exported properties.
func _find_music_data(node: Node) -> MusicData:
	var d: Variant = node.get("music_data")
	if d is MusicData:
		return d
	for c in node.get_children():
		var found := _find_music_data(c)
		if found != null:
			return found
	return null

func _show_rows(rows: Array, status: String) -> void:
	_tree.clear()
	var tr := _tree.create_item()
	for r in rows:
		var it := _tree.create_item(tr)
		it.set_text(0, r["name"])
		it.set_text(1, r["type"])
		it.set_text(2, r["pattern"])
		it.set_text(3, r["patch"])
		it.set_text(4, str(r["channel"]))
		it.set_text(5, str(r["octave"]))
		it.set_text_alignment(4, HORIZONTAL_ALIGNMENT_RIGHT)
		it.set_text_alignment(5, HORIZONTAL_ALIGNMENT_RIGHT)
	_status_label.text = status

## Plain-text snapshot of the rows, for tests and logs.
func get_rows() -> Array:
	var out: Array = []
	var it := _tree.get_root().get_first_child() if _tree.get_root() != null else null
	while it != null:
		var row := []
		for i in COLUMNS.size():
			row.append(it.get_text(i))
		out.append(row)
		it = it.get_next()
	return out

static func _res_name(res: Resource, fallback: String) -> String:
	if res == null:
		return fallback
	if res.resource_path != "" and not "::" in res.resource_path:
		return res.resource_path.get_file()
	return "(inline)"

static func _patch_name(p: SynthPatch) -> String:
	if p == null:
		return "-"
	if p.resource_path != "" and not "::" in p.resource_path:
		return p.resource_path.get_file()
	return "(inline) " + p.patch_name
