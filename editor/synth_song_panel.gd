@tool
class_name SynthSongPanel
extends PanelContainer

# The Track view's song editor, under the lanes while the scene plays a MusicSong:
#
#   song      where it lives, its beats per bar and its also_bake list, Save song as...
#   entries   add a new section, add one the song already has, duplicate, remove, move,
#             how often the entry plays, and where the song loops back to
#   preview   play the song from the selected section, loop that section
#   section   the selected entry's section: name, repeats, its own progression, and
#             one row per MusicTrack of the scene with what the section does with it
#             (Play a pattern or chain, Silent, Keep)
#
# It owns no data. A change is reported by a signal and the view turns it into an
# undo action on the scene. When the scene is not open in the editor everything is
# read-only.

const MODE_NAMES := ["Play", "Silent", "Keep"]
const READONLY_TIP := "The scene is not open in the editor, so its song is read-only."

signal entry_action(action: StringName)
signal add_existing_requested(section: MusicSection)
signal entry_repeats_edited(value: int)
signal section_name_edited(text: String)
signal section_repeats_edited(value: int)
signal own_progression_toggled(on: bool)
## [param mode] is a MusicSectionSlot.Mode.
signal slot_mode_edited(track: StringName, mode: int)
signal slot_pattern_edited(track: StringName, pattern: MusicPattern)
signal slot_open_requested(track: StringName)
signal beats_per_bar_edited(value: int)
## [param section] null: a new, empty section.
signal also_bake_added(section: MusicSection)
signal also_bake_removed(index: int)
signal save_song_requested
signal play_section_requested
signal loop_section_toggled(on: bool)

var _banner: Label
var _title: Label
var _where: Label
var _save: Button
var _bpb: SpinBox
var _bake_box: HFlowContainer
var _bake_chips: Array[Control] = []
var _bake_add: MenuButton
var _add_new: Button
var _add_existing: MenuButton
var _duplicate: Button
var _remove: Button
var _left: Button
var _right: Button
var _entry_repeats: SpinBox
var _loop_here: Button
var _entry_info: Label
var _play: Button
var _loop: Button
var _swatch: ColorRect
var _name: LineEdit
var _repeats: SpinBox
var _own: CheckBox
var _section_box: VBoxContainer
var _slot_rows: VBoxContainer
var _slots: Array[Dictionary] = []
var _orphans: Label
var _editable: bool = true
var _shown_name: String = ""
var _existing: Array = []
var _bake_candidates: Array = []

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	_banner = _wrapped()
	root.add_child(_banner)

	# Song.
	var song := _flow(root)
	_title = Label.new()
	_title.text = "Song"
	_title.add_theme_font_size_override("font_size", 15)
	song.add_child(_title)
	_where = Label.new()
	_where.add_theme_color_override("font_color", SynthRackStyle.accent(self))
	_where.mouse_filter = Control.MOUSE_FILTER_PASS
	song.add_child(_where)
	_save = _button("Save song as...", "Save the song to a .tres file the player then uses (undoable).",
			func(): save_song_requested.emit())
	song.add_child(_save)
	song.add_child(_dim_label("Beats per bar", "Where NEXT_BAR queues take over and where the ruler counts bars, from the start of each section."))
	_bpb = _spin(1, 32, 1)
	_bpb.tooltip_text = "MusicSong.beats_per_bar."
	_bpb.value_changed.connect(func(v: float): beats_per_bar_edited.emit(int(v)))
	song.add_child(_bpb)
	song.add_child(_dim_label("Also bake", "Sections no entry plays that the game queues. They are baked like the entries' sections: MusicSong.also_bake."))
	_bake_box = _flow(song)
	_bake_add = MenuButton.new()
	_bake_add.text = "Add..."
	_bake_add.flat = false
	_bake_add.focus_mode = Control.FOCUS_NONE
	_bake_add.tooltip_text = "List a section the game queues without playing it in the song: a new empty one, or one the song has."
	_bake_add.get_popup().id_pressed.connect(_on_bake_add)
	_bake_box.add_child(_bake_add)

	# Entries.
	var entries := _flow(root)
	entries.add_child(_dim_label("Entry", "An entry plays a section, one or more times in a row."))
	_add_new = _button("Add section", "Add an entry after the selected one, with a new empty section (it plays the song's progression and keeps every track).",
			func(): entry_action.emit(&"add_new"))
	entries.add_child(_add_new)
	_add_existing = MenuButton.new()
	_add_existing.text = "Add existing..."
	_add_existing.focus_mode = Control.FOCUS_NONE
	_add_existing.tooltip_text = "Add an entry after the selected one that plays a section the song already has. The section is shared: editing it changes every entry that plays it."
	_add_existing.get_popup().id_pressed.connect(_on_add_existing)
	entries.add_child(_add_existing)
	_duplicate = _button("Duplicate", "Add an entry after the selected one with a copy of its section (own progression and slots copied, patterns shared), to write a variation.",
			func(): entry_action.emit(&"duplicate"))
	entries.add_child(_duplicate)
	_left = _button("<", "Move the entry one place earlier.", func(): entry_action.emit(&"left"))
	entries.add_child(_left)
	_right = _button(">", "Move the entry one place later.", func(): entry_action.emit(&"right"))
	entries.add_child(_right)
	_remove = _button("Remove", "Remove the entry. Its section stays in the song if another entry plays it.", func(): entry_action.emit(&"remove"))
	entries.add_child(_remove)
	entries.add_child(_dim_label("Plays", "How many times in a row the entry plays its section. Each time is a fresh start of the section."))
	_entry_repeats = _spin(1, 64, 1)
	_entry_repeats.tooltip_text = "MusicSongEntry.repeats."
	_entry_repeats.value_changed.connect(func(v: float): entry_repeats_edited.emit(int(v)))
	entries.add_child(_entry_repeats)
	_loop_here = _button("Loop from here", "After its last entry the song continues from this one: MusicSong.loop_entry.",
			func(): entry_action.emit(&"loop_here"))
	entries.add_child(_loop_here)
	_entry_info = Label.new()
	_entry_info.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_entry_info.mouse_filter = Control.MOUSE_FILTER_PASS
	entries.add_child(_entry_info)

	# Preview.
	var prev := _flow(root)
	prev.add_child(_dim_label("Preview", "Plays through the real song player, so what you hear is what the game plays."))
	_play = _button("Play from section", "Play the song from the start of the selected section.", func(): play_section_requested.emit())
	prev.add_child(_play)
	_loop = Button.new()
	_loop.text = "Loop section"
	_loop.toggle_mode = true
	_loop.focus_mode = Control.FOCUS_NONE
	_loop.tooltip_text = "Repeat the selected section while you write it (each pass restarts its PLAY slots). Pick another entry and it loops that one from the next boundary."
	_loop.toggled.connect(func(on: bool): loop_section_toggled.emit(on))
	prev.add_child(_loop)

	root.add_child(HSeparator.new())

	# Section.
	_section_box = VBoxContainer.new()
	_section_box.add_theme_constant_override("separation", 6)
	root.add_child(_section_box)
	var sec := _flow(_section_box)
	_swatch = ColorRect.new()
	_swatch.custom_minimum_size = Vector2(6.0 * SynthRackStyle.scale(self), 18.0 * SynthRackStyle.scale(self))
	_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_swatch.tooltip_text = "The section's colour in the strip and the lanes."
	sec.add_child(_swatch)
	sec.add_child(_dim_label("Section", "The section of the selected entry."))
	_name = LineEdit.new()
	_name.custom_minimum_size.x = 120.0 * SynthRackStyle.scale(self)
	_name.placeholder_text = "Name"
	_name.tooltip_text = "MusicSection.name. play_from_section() and queue_section() find the section by it."
	_name.text_submitted.connect(func(_t: String): _commit_name())
	_name.focus_exited.connect(_commit_name)
	sec.add_child(_name)
	sec.add_child(_dim_label("Repeats", "How many times the section's progression plays inside it. Patterns are not restarted between repeats."))
	_repeats = _spin(1, 64, 1)
	_repeats.tooltip_text = "MusicSection.repeats."
	_repeats.value_changed.connect(func(v: float): section_repeats_edited.emit(int(v)))
	sec.add_child(_repeats)
	_own = CheckBox.new()
	_own.text = "Own progression"
	_own.focus_mode = Control.FOCUS_NONE
	_own.tooltip_text = "Off: the section plays the song's progression. On: it gets a copy of it to edit with the block editor below."
	_own.toggled.connect(func(on: bool): own_progression_toggled.emit(on))
	sec.add_child(_own)

	var sh := _dim_label("Tracks", "What the section does with each MusicTrack of the scene when it starts. A track it does not list keeps going.")
	_section_box.add_child(sh)
	_slot_rows = VBoxContainer.new()
	_slot_rows.add_theme_constant_override("separation", 4)
	_section_box.add_child(_slot_rows)
	_orphans = _wrapped()
	_orphans.add_theme_color_override("font_color", SynthRackStyle.warn(self))
	_orphans.mouse_filter = Control.MOUSE_FILTER_STOP
	_section_box.add_child(_orphans)

func _ready() -> void:
	_restyle()

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_restyle()

var _restyling := false

func _restyle() -> void:
	if _restyling or _title == null:
		return
	_restyling = true
	add_theme_stylebox_override("panel", SynthRackStyle.make_card_style(self))
	_restyling = false

func _flow(parent: Control) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 8)
	f.add_theme_constant_override("v_separation", 4)
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(f)
	return f

func _wrapped() -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 120.0
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func _dim_label(text: String, tip: String) -> Label:
	var l := Label.new()
	l.text = text
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func _button(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = hi
	sp.step = step
	sp.allow_greater = true
	sp.custom_minimum_size.x = 76.0 * SynthRackStyle.scale(self)
	return sp

func _commit_name() -> void:
	if _name.text == _shown_name:
		return
	_shown_name = _name.text
	section_name_edited.emit(_name.text)

# ---------------------------------------------------------------------------
# Showing a song
# ---------------------------------------------------------------------------

## Show the song and the selected entry. [param info]:
##   editable (bool), banner (String shown when read-only), where (String: the song's
##   file or "inline"), beats_per_bar, entry (int, -1 none), entry_count,
##   entry_repeats, can_loop_here (bool: not already the loop entry), loop_entry,
##   section (MusicSection or null), color (Color), section_name, section_repeats,
##   own (bool), can_own (bool), tracks (Array of {name, mode (MusicSectionSlot.Mode),
##   pattern, track_pattern}), orphans (PackedStringArray: slots naming no track),
##   existing (Array of MusicSection the song has), also_bake (Array of section names),
##   also_candidates (Array of MusicSection), loop_on, can_play.
func show_song(info: Dictionary) -> void:
	_editable = info.get("editable", false)
	_banner.text = info.get("banner", "")
	_banner.visible = _banner.text != ""
	_where.text = info.get("where", "")
	_save.disabled = not _editable
	_save.tooltip_text = "Save the song to a .tres file the player then uses (undoable)." if _editable else READONLY_TIP
	_bpb.set_value_no_signal(info.get("beats_per_bar", 4))
	_bpb.editable = _editable
	_show_bake(info)

	var entry: int = info.get("entry", -1)
	var count: int = info.get("entry_count", 0)
	var has := entry >= 0
	_add_new.disabled = not _editable
	_add_existing.disabled = not _editable
	_existing = info.get("existing", [])
	var pop := _add_existing.get_popup()
	pop.clear()
	for i in _existing.size():
		pop.add_item(SynthSongLayout.section_label(_existing[i]), i)
	_add_existing.disabled = not _editable or _existing.is_empty()
	_duplicate.disabled = not _editable or not has
	_remove.disabled = not _editable or not has or count <= 1
	_left.disabled = not _editable or not has or entry <= 0
	_right.disabled = not _editable or not has or entry >= count - 1
	_entry_repeats.set_value_no_signal(info.get("entry_repeats", 1))
	_entry_repeats.editable = _editable and has
	_loop_here.disabled = not _editable or not has or not info.get("can_loop_here", false)
	_entry_info.text = "" if not has else "entry %d of %d%s" % [entry + 1, count, "  (the song loops from here)" if entry == info.get("loop_entry", 0) else ""]
	_play.disabled = not info.get("can_play", false)
	_loop.set_pressed_no_signal(info.get("loop_on", false))
	_loop.disabled = not has

	var section: MusicSection = info.get("section")
	_section_box.visible = section != null
	if section == null:
		return
	_swatch.color = info.get("color", Color.WHITE)
	_shown_name = info.get("section_name", "")
	if not _name.has_focus():
		_name.text = _shown_name
	_name.editable = _editable
	_repeats.set_value_no_signal(info.get("section_repeats", 1))
	_repeats.editable = _editable
	_own.set_pressed_no_signal(info.get("own", false))
	_own.disabled = not _editable or not info.get("can_own", false)
	_show_slots(info.get("tracks", []))
	var orphans: PackedStringArray = info.get("orphans", PackedStringArray())
	_orphans.visible = not orphans.is_empty()
	_orphans.text = "Slots for tracks this scene does not have: %s." % ", ".join(orphans)
	_orphans.tooltip_text = "These slots name no MusicTrack here, so they do nothing in this scene."

func _show_bake(info: Dictionary) -> void:
	for c in _bake_chips:
		c.get_parent().remove_child(c)
		c.queue_free()
	_bake_chips.clear()
	var names: Array = info.get("also_bake", [])
	for i in names.size():
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 2)
		var l := Label.new()
		l.text = String(names[i])
		chip.add_child(l)
		var x := Button.new()
		x.text = "x"
		x.flat = true
		x.focus_mode = Control.FOCUS_NONE
		x.disabled = not _editable
		x.tooltip_text = "Take this section out of also_bake."
		x.pressed.connect(func(): also_bake_removed.emit(_bake_chips.find(chip)))
		chip.add_child(x)
		_bake_box.add_child(chip)
		_bake_box.move_child(chip, i)
		_bake_chips.append(chip)
	_bake_candidates = info.get("also_candidates", [])
	var pop := _bake_add.get_popup()
	pop.clear()
	pop.add_item("New section", 0)
	for i in _bake_candidates.size():
		pop.add_item(SynthSongLayout.section_label(_bake_candidates[i]), i + 1)
	_bake_add.disabled = not _editable

func _on_add_existing(id: int) -> void:
	if id >= 0 and id < _existing.size():
		add_existing_requested.emit(_existing[id])

func _on_bake_add(id: int) -> void:
	if id == 0:
		also_bake_added.emit(null)
	elif id - 1 < _bake_candidates.size():
		also_bake_added.emit(_bake_candidates[id - 1])

func _show_slots(tracks: Array) -> void:
	while _slots.size() > tracks.size():
		var gone: HBoxContainer = _slots.pop_back()["row"]
		_slot_rows.remove_child(gone)
		gone.queue_free()
	while _slots.size() < tracks.size():
		_slots.append(_make_slot())
	for i in tracks.size():
		_sync_slot(i, tracks[i])

func _make_slot() -> Dictionary:
	var row := {}
	var box := HFlowContainer.new()
	box.add_theme_constant_override("h_separation", 6)
	box.add_theme_constant_override("v_separation", 2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_rows.add_child(box)
	var name_l := Label.new()
	name_l.custom_minimum_size.x = 96.0 * SynthRackStyle.scale(self)
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(name_l)
	var mode := OptionButton.new()
	mode.focus_mode = Control.FOCUS_NONE
	for i in MODE_NAMES.size():
		mode.add_item(MODE_NAMES[i], i)
	mode.tooltip_text = "Play: start the pattern on the section's first beat (restarting it). Silent: stop the track. Keep: carry on with what it plays."
	mode.item_selected.connect(func(i: int): slot_mode_edited.emit(StringName(name_l.text), mode.get_item_id(i)))
	box.add_child(mode)
	var field := SynthResourceField.new()
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.custom_minimum_size.x = 150.0 * SynthRackStyle.scale(self)
	field.setup("MusicPattern")
	field.tooltip_text = "The pattern or chain to play. Empty: the track's own pattern."
	field.resource_changed.connect(func(r: Resource): slot_pattern_edited.emit(StringName(name_l.text), r as MusicPattern))
	field.resource_opened.connect(func(_r: Resource): slot_open_requested.emit(StringName(name_l.text)))
	box.add_child(field)
	var open := _button("Open in Pattern", "Edit this pattern in Pattern.", func(): slot_open_requested.emit(StringName(name_l.text)))
	box.add_child(open)
	row["row"] = box
	row["name"] = name_l
	row["mode"] = mode
	row["field"] = field
	row["open"] = open
	return row

func _sync_slot(i: int, t: Dictionary) -> void:
	var row := _slots[i]
	(row["name"] as Label).text = String(t["name"])
	(row["name"] as Label).tooltip_text = String(t["name"])
	var mode := row["mode"] as OptionButton
	mode.select(mode.get_item_index(int(t["mode"])))
	mode.disabled = not _editable
	var play: bool = int(t["mode"]) == MusicSectionSlot.Mode.PLAY
	var field := row["field"] as SynthResourceField
	field.visible = play
	field.set_resource(t["pattern"])
	field.editable = _editable
	var open := row["open"] as Button
	open.visible = play
	open.disabled = t["pattern"] == null and t.get("track_pattern") == null

# ---------------------------------------------------------------------------
# For tests
# ---------------------------------------------------------------------------

func get_controls() -> Dictionary:
	return {"banner": _banner, "where": _where, "save": _save, "beats_per_bar": _bpb, "bake_add": _bake_add,
			"add_new": _add_new, "add_existing": _add_existing, "duplicate": _duplicate, "remove": _remove,
			"left": _left, "right": _right, "entry_repeats": _entry_repeats, "loop_here": _loop_here,
			"entry_info": _entry_info, "play": _play, "loop": _loop, "name": _name, "repeats": _repeats,
			"own": _own, "section_box": _section_box, "orphans": _orphans, "swatch": _swatch}

func get_slot_count() -> int:
	return _slots.size() if _section_box.visible else 0

## Slot row [param i]'s widgets: row, name, mode, field, open.
func get_slot_row(i: int) -> Dictionary:
	return _slots[i]

func get_also_bake_chips() -> Array[Control]:
	return _bake_chips

func is_read_only() -> bool:
	return not _editable
