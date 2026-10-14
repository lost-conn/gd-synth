@tool
class_name SynthMixedSpin
extends SpinBox

# A number field for an inspector that edits several things at once. When the
# things disagree it shows "—"; typing a number (or stepping the arrows) then
# sets all of them.
#
# It reports through `edited(value)` only: a change the user made, never one the
# panel set by showing a selection (set_values is silent). The same typed value is
# reported once, however many of the field's own signals (value_changed,
# text_submitted, focus_exited) carried it.

signal edited(value: float)

const MIXED := "—"

var _mixed: bool = false
var _empty: bool = false
var _shown: float = 0.0

func _ready() -> void:
	select_all_on_focus = true
	value_changed.connect(_on_value_changed)
	var le := get_line_edit()
	le.text_submitted.connect(_on_text)
	le.focus_exited.connect(_on_focus_exited)
	# SpinBox rewrites its text from the number on some redraws; keep the dash.
	draw.connect(_keep_mixed)

## Show [param values]: their common value, or "—" when they differ (or none).
func set_values(values: Array) -> void:
	_empty = values.is_empty()
	if _empty:
		_mixed = false
		set_value_no_signal(min_value)
		editable = false
		get_line_edit().text = ""
		return
	editable = true
	var first: float = values[0]
	_mixed = false
	for v in values:
		if not is_equal_approx(float(v), first):
			_mixed = true
			break
	_shown = first
	set_value_no_signal(first)
	if _mixed:
		get_line_edit().text = MIXED

func is_mixed() -> bool:
	return _mixed

func _on_value_changed(v: float) -> void:
	_commit(v)

func _on_text(text: String) -> void:
	if text.strip_edges() == MIXED:
		return
	if text.is_valid_float():
		_commit(clampf(text.to_float(), min_value, max_value if not allow_greater else INF))

func _keep_mixed() -> void:
	var le := get_line_edit()
	if _mixed and not le.has_focus() and le.text != MIXED:
		le.text = MIXED
	elif _empty and le.text != "":
		le.text = ""

func _on_focus_exited() -> void:
	# Leaving a field that still reads "—" keeps it that way.
	if _mixed:
		get_line_edit().text = MIXED

func _commit(v: float) -> void:
	if not _mixed and is_equal_approx(v, _shown):
		return
	_mixed = false
	_shown = v
	edited.emit(v)
