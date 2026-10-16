@tool
class_name SynthIntervalEditor
extends HBoxContainer

# Edits a list of semitone offsets from a root: a row of toggle chips per octave
# (named after the notes they give above the root) and a text field ("0, 4, 7, 14")
# for the same list. The Track view's block drawer uses one for a block's custom
# chord_intervals (two octaves, so 9ths, 11ths and 13ths are possible) and one for a
# custom scale_intervals (one octave).
#
# The root (0) is always on, and the list is kept sorted and free of duplicates:
# see SynthHarmony.clean_intervals. The editor only reports what the user asked for;
# whoever owns the data applies it and calls set_intervals with the result.

## The user changed the list (chip clicked or text accepted). Already cleaned.
signal intervals_changed(intervals: PackedInt32Array)

## Highest offset the editor offers (11 = one octave, 23 = two).
var max_interval: int = 11

var _intervals := PackedInt32Array([0])
var _root: int = 0
var _chips: Array[Button] = []
var _text: LineEdit
var _caption: Label
var _editable: bool = true

## [param caption]: what the list is ("Chord tones"). [param octaves]: 1 or 2 rows.
## [param ui_scale]: SynthRackStyle.scale.
func setup(caption: String, octaves: int, ui_scale: float) -> void:
	max_interval = octaves * 12 - 1
	add_theme_constant_override("separation", 8)
	_caption = Label.new()
	_caption.text = caption
	_caption.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_caption.custom_minimum_size.x = 80.0 * ui_scale
	_caption.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	add_child(_caption)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 2)
	add_child(col)
	for o in octaves:
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 2)
		row.add_theme_constant_override("v_separation", 2)
		col.add_child(row)
		if octaves > 1:
			var l := Label.new()
			l.text = "Root octave" if o == 0 else "Octave up"
			l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
			l.custom_minimum_size.x = 72.0 * ui_scale
			row.add_child(l)
		for k in 12:
			var v := o * 12 + k
			var b := Button.new()
			b.toggle_mode = true
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size.x = 34.0 * ui_scale
			b.pressed.connect(_on_chip_pressed.bind(v))
			row.add_child(b)
			_chips.append(b)
	_text = LineEdit.new()
	_text.custom_minimum_size.x = 180.0 * ui_scale
	_text.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_text.tooltip_text = "The same list as text: semitones above the root, 0 to %d, separated by commas (for example 0, 4, 7, 14). Press Enter to apply. The root (0) is always kept; the list is sorted and duplicates are dropped." % max_interval
	_text.text_submitted.connect(func(_t: String): _commit_text())
	_text.focus_exited.connect(_commit_text)
	col.add_child(_text)
	_refresh()

## Show [param iv] (without telling anyone). A value outside the chips' range is
## listed in the text field only.
func set_intervals(iv: PackedInt32Array) -> void:
	_intervals = iv
	_refresh()

## Name the chips after the notes they give above [param root] (0=C ... 11=B).
func set_root(root: int) -> void:
	_root = posmod(root, 12)
	_refresh()

func set_editable(e: bool) -> void:
	_editable = e
	_refresh()

func get_intervals() -> PackedInt32Array:
	return _intervals

## The chips, lowest offset first, for tests.
func get_chips() -> Array[Button]:
	return _chips

func get_text_edit() -> LineEdit:
	return _text

func _refresh() -> void:
	if _chips.is_empty():
		return
	for v in _chips.size():
		var b := _chips[v]
		var note: String = SynthHarmony.NOTE_NAMES[(_root + v) % 12]
		b.text = note
		b.set_pressed_no_signal(_intervals.has(v))
		b.disabled = not _editable
		b.tooltip_text = "Root: always part of the list, so it cannot be switched off." if v == 0 else "%s: %d semitones above the root. Click to add or remove it." % [note, v]
	# Never rewrite the text under the user's typing.
	if not _text.has_focus():
		_text.text = SynthHarmony.intervals_text(_intervals)
	_text.editable = _editable

func _on_chip_pressed(v: int) -> void:
	_apply(SynthHarmony.toggled_intervals(_intervals, v, max_interval))

func _commit_text() -> void:
	if _editable:
		var parsed := SynthHarmony.parse_intervals(_text.text, max_interval)
		if not parsed.is_empty():
			_apply(parsed)
	# Show the list as it stands: the cleaned version, or the old one for bad text.
	_text.text = SynthHarmony.intervals_text(_intervals)

func _apply(iv: PackedInt32Array) -> void:
	if iv == _intervals:
		_refresh()
		return
	_intervals = iv
	_refresh()
	intervals_changed.emit(iv)
