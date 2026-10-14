@tool
class_name SynthPatchBrowser
extends VBoxContainer

# The Sound view's left column: every SynthPatch file in the project, grouped by
# folder with a hint of where each is used, and below it a grid of the factory
# presets to start a new patch from.
#
# It only reports what was picked; whether picking is allowed right now (unsaved
# edits) is the rack's business.

signal patch_chosen(path: String)
signal preset_chosen(preset_id: int)

## [label, tooltip, factory] for each SynthPatch.make_*(), in the order shown.
const PRESETS := [
	["Organ", "Organ", &"make_organ"],
	["Clarinet", "Clarinet", &"make_clarinet"],
	["Bell", "Bell (inharmonic partials)", &"make_bell"],
	["Pad", "Pad", &"make_pad"],
	["Bass", "Bass", &"make_bass"],
	["Kick", "Kick", &"make_kick"],
	["Snare", "Snare", &"make_snare"],
	["Hi-Hat", "Hi-Hat", &"make_hihat"],
	["FM Bell", "FM Bell", &"make_fm_bell"],
	["FM EPiano", "FM EPiano", &"make_fm_epiano"],
	["FM Clang", "FM Clang", &"make_fm_clang"],
	["Acid", "Acid Bass", &"make_acid_bass"],
	["Pluck", "Filter Pluck", &"make_filter_pluck"],
	["Sweep", "Sweep SFX", &"make_sweep_sfx"],
	["Snare+", "Snare Snappy", &"make_snare_snappy"],
	["Hat Open", "Hi-Hat Open", &"make_hihat_open"],
	["Crash", "Cymbal Crash", &"make_cymbal_crash"],
]

var index: SynthProjectIndex
## Path of the patch the view is editing ("" for an unsaved one): its row is selected.
var current_path: String = ""

var _search: LineEdit
var _tree: Tree
var _count: Label
var _grid: GridContainer
var _suppress: bool = false

func _ready() -> void:
	var s := SynthRackStyle.scale(self)
	add_theme_constant_override("separation", 6)

	var head := Label.new()
	head.text = "Patches"
	head.add_theme_font_size_override("font_size", 15)
	add_child(head)

	_search = LineEdit.new()
	_search.placeholder_text = "Filter..."
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): rebuild())
	add_child(_search)

	_tree = Tree.new()
	_tree.columns = 2
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_SINGLE
	_tree.column_titles_visible = false
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, roundi(64.0 * s))
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 120.0 * s)
	_tree.item_selected.connect(_on_item_selected)
	add_child(_tree)

	_count = Label.new()
	_count.add_theme_font_size_override("font_size", 11)
	_count.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	add_child(_count)

	var pl := Label.new()
	pl.text = "Start from a preset"
	pl.add_theme_font_size_override("font_size", 13)
	add_child(pl)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 3)
	_grid.add_theme_constant_override("v_separation", 3)
	add_child(_grid)
	for i in PRESETS.size():
		var b := Button.new()
		b.text = PRESETS[i][0]
		b.tooltip_text = "New unsaved patch from the %s preset." % PRESETS[i][1]
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.custom_minimum_size = Vector2(0, 0)
		b.pressed.connect(func(): preset_chosen.emit(i))
		_grid.add_child(b)
	rebuild()

## Make the preset [param id]'s patch.
static func make_preset(id: int) -> SynthPatch:
	return Callable(SynthPatch, PRESETS[id][2]).call() as SynthPatch

## Rebuild the list from the index.
func rebuild() -> void:
	if _tree == null:
		return
	_suppress = true
	_tree.clear()
	var root := _tree.create_item()
	var dirs: Dictionary = {}
	var needle := _search.text.strip_edges().to_lower()
	var shown := 0
	var selected: TreeItem = null
	if index != null:
		for p in index.patches:
			var path: String = p["path"]
			if needle != "" and not (path.to_lower().contains(needle)):
				continue
			var dir: String = p["dir"]
			if not dirs.has(dir):
				var d := _tree.create_item(root)
				d.set_text(0, dir.trim_prefix("res://") if dir != "res://" else "res://")
				d.set_selectable(0, false)
				d.set_selectable(1, false)
				d.set_custom_color(0, SynthRackStyle.dim(self))
				dirs[dir] = d
			var item := _tree.create_item(dirs[dir])
			item.set_text(0, p["name"])
			item.set_tooltip_text(0, path)
			item.set_metadata(0, path)
			item.set_text(1, index.usage_hint(path))
			item.set_custom_color(1, SynthRackStyle.dim(self))
			item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
			if path == current_path:
				selected = item
			shown += 1
	if selected != null:
		selected.select(0)
		_tree.scroll_to_item(selected)
	_count.text = "%d patch%s" % [shown, "" if shown == 1 else "es"]
	_suppress = false

## Highlight the row of [param path] (none if it is "" or not listed).
func select_path(path: String) -> void:
	current_path = path
	if _tree == null:
		return
	_suppress = true
	_tree.deselect_all()
	var root := _tree.get_root()
	if root != null and path != "":
		for d in root.get_children():
			for it in d.get_children():
				if it.get_metadata(0) == path:
					it.select(0)
					_tree.scroll_to_item(it)
	_suppress = false

## Refresh the hint column (after the reference scan finished).
func refresh_hints() -> void:
	if _tree == null or _tree.get_root() == null or index == null:
		return
	for d in _tree.get_root().get_children():
		for it in d.get_children():
			it.set_text(1, index.usage_hint(str(it.get_metadata(0))))

## Row paths in display order (for tests).
func get_listed_paths() -> PackedStringArray:
	var out := PackedStringArray()
	if _tree != null and _tree.get_root() != null:
		for d in _tree.get_root().get_children():
			for it in d.get_children():
				out.append(str(it.get_metadata(0)))
	return out

func _on_item_selected() -> void:
	if _suppress:
		return
	var it := _tree.get_selected()
	if it != null and it.get_metadata(0) != null:
		patch_chosen.emit(str(it.get_metadata(0)))
