@tool
class_name SynthHarmonicsEditor
extends VBoxContainer

# The additive oscillator's partials as bars: drag across the bars to paint
# amplitudes (right-click zeroes one), click a bar's number to pick a partial and
# set its exact amplitude and its frequency ratio below. SynthPatch stores
# `harmonics` (amplitudes) and `harmonic_ratios` (0 = the integer multiple n),
# both unbounded in length; this shows 8 to 32 partials at a time.
#
# Like SynthRackParam it reports instead of writing:
#   live       the paint stroke is under way; apply the array as it stands
#   committed  the stroke ended or a field was entered; record old -> new

signal live(prop: StringName, value: PackedFloat32Array)
signal committed(prop: StringName, new_value: PackedFloat32Array, old_value: PackedFloat32Array)

const MIN_SLOTS := 8
const MAX_SLOTS := 32
# Partial ratios offered by the ratio field.
const MAX_RATIO := 64.0

var patch: SynthPatch

var _bars: Control
var _slots: int = MIN_SLOTS
var _selected: int = 0
var _count_spin: SpinBox
var _amp_spin: SpinBox
var _ratio_spin: SpinBox
var _sel_label: Label
var _stroke_old: PackedFloat32Array
var _stroking: bool = false
var _stroke_button: int = 0

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	var s := SynthRackStyle.scale(self)

	_bars = Control.new()
	_bars.custom_minimum_size = Vector2(0, 104.0 * s)
	_bars.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bars.mouse_filter = Control.MOUSE_FILTER_STOP
	_bars.draw.connect(_draw_bars)
	_bars.gui_input.connect(_on_bars_input)
	_bars.resized.connect(_bars.queue_redraw)
	_bars.tooltip_text = ""
	add_child(_bars)

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 2)
	add_child(row)

	_sel_label = Label.new()
	_sel_label.custom_minimum_size = Vector2(62.0 * s, 0)
	row.add_child(_sel_label)

	row.add_child(_small_label("Amp"))
	_amp_spin = _make_spin(0.0, 1.0, 0.001, s)
	_amp_spin.tooltip_text = "Amplitude of the selected partial, 0 to 1."
	_amp_spin.value_changed.connect(_on_amp_field)
	row.add_child(_amp_spin)

	row.add_child(_small_label("Ratio"))
	_ratio_spin = _make_spin(0.0, MAX_RATIO, 0.01, s)
	_ratio_spin.tooltip_text = "Frequency ratio of the selected partial. 0 = the integer multiple (1, 2, 3...). Inharmonic ratios such as 2.76 make bell-like tones."
	_ratio_spin.value_changed.connect(_on_ratio_field)
	row.add_child(_ratio_spin)

	row.add_child(_small_label("Partials"))
	_count_spin = _make_spin(1, MAX_SLOTS, 1, s)
	_count_spin.tooltip_text = "How many partials are shown. Lowering it below the patch's own count cuts the extra partials off."
	_count_spin.value_changed.connect(_on_count_field)
	row.add_child(_count_spin)
	_update_fields()

func _make_spin(mn: float, mx: float, step: float, s: float) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	sp.select_all_on_focus = true
	sp.custom_minimum_size = Vector2(82.0 * s, 0)
	return sp

func _small_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func set_patch(p: SynthPatch) -> void:
	if p != patch:
		_selected = 0
		_slots = MIN_SLOTS
	patch = p
	refresh()

## Re-read the patch (after an edit made elsewhere).
func refresh() -> void:
	if patch == null or _bars == null:
		return
	_slots = clampi(maxi(_slots, patch.harmonics.size()), 1, MAX_SLOTS)
	_selected = clampi(_selected, 0, _slots - 1)
	_update_fields()
	_bars.queue_redraw()

func get_slots() -> int:
	return _slots

func get_selected() -> int:
	return _selected

# ---------------------------------------------------------------------------

func _amp_at(i: int) -> float:
	return patch.harmonics[i] if i < patch.harmonics.size() else 0.0

func _ratio_at(i: int) -> float:
	return patch.harmonic_ratios[i] if i < patch.harmonic_ratios.size() else 0.0

func _update_fields() -> void:
	if _count_spin == null or patch == null:
		return
	_count_spin.set_value_no_signal(_slots)
	_sel_label.text = "Partial %d" % (_selected + 1)
	_amp_spin.set_value_no_signal(_amp_at(_selected))
	_ratio_spin.set_value_no_signal(_ratio_at(_selected))

func _plot() -> Rect2:
	var s := SynthRackStyle.scale(self)
	var label_h: float = 16.0 * s
	return Rect2(2, 2, maxf(_bars.size.x - 4.0, 1.0), maxf(_bars.size.y - label_h - 4.0, 1.0))

func _slot_at(x: float) -> int:
	var pr := _plot()
	return clampi(int((x - pr.position.x) / pr.size.x * _slots), 0, _slots - 1)

func _draw_bars() -> void:
	if patch == null:
		return
	var pr := _plot()
	var acc := SynthRackStyle.accent(self)
	var grid := SynthRackStyle.grid(self)
	var dim := SynthRackStyle.dim(self)
	var s := SynthRackStyle.scale(self)
	_bars.draw_rect(Rect2(Vector2.ZERO, _bars.size), SynthRackStyle.inset(self))
	for k in [0.25, 0.5, 0.75]:
		var gy: float = pr.end.y - k * pr.size.y
		_bars.draw_line(Vector2(pr.position.x, gy), Vector2(pr.end.x, gy), grid, 1.0)
	var col_w: float = pr.size.x / float(_slots)
	var fnt := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.75)
	var show_every: int = 1 if col_w >= 15.0 * s else (2 if col_w >= 8.0 * s else 4)
	for i in _slots:
		var amp: float = clampf(_amp_at(i), 0.0, 1.0)
		var x: float = pr.position.x + i * col_w
		var bar := Rect2(x + 1.0, pr.end.y - amp * pr.size.y, maxf(col_w - 2.0, 1.0), maxf(amp * pr.size.y, 1.0))
		var c := acc
		if i == _selected:
			c = acc.lightened(0.25)
		elif i >= patch.harmonics.size():
			c.a = 0.35
		_bars.draw_rect(bar, c)
		var ratio: float = _ratio_at(i)
		if ratio > 0.0 and absf(ratio - float(i + 1)) > 0.001:
			# Detuned from its integer slot: a tick above the bar.
			_bars.draw_rect(Rect2(x + 1.0, bar.position.y - 3.0 * s, bar.size.x, 2.0 * s), SynthRackStyle.marker(self))
		if i % show_every == 0:
			var txt := str(i + 1)
			var w: float = fnt.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_bars.draw_string(fnt, Vector2(x + (col_w - w) * 0.5, _bars.size.y - 3.0 * s), txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SynthRackStyle.text(self) if i == _selected else dim)
	_bars.draw_rect(Rect2(Vector2.ZERO, _bars.size), grid, false, 1.0)

func _on_bars_input(event: InputEvent) -> void:
	if patch == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT and mb.button_index != MOUSE_BUTTON_RIGHT:
			return
		if mb.pressed:
			_selected = _slot_at(mb.position.x)
			_update_fields()
			_bars.queue_redraw()
			# A click on the numbers below the bars only picks the partial.
			if mb.position.y > _plot().end.y:
				return
			_stroking = true
			_stroke_button = mb.button_index
			_stroke_old = patch.harmonics.duplicate()
			_paint(mb.position)
		elif _stroking and mb.button_index == _stroke_button:
			_stroking = false
			var now: PackedFloat32Array = patch.harmonics.duplicate()
			if now != _stroke_old:
				committed.emit(&"harmonics", now, _stroke_old)
			_bars.queue_redraw()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if not _stroking:
			_bars.tooltip_text = _tooltip_for(_slot_at(mm.position.x))
			return
		var i := _slot_at(mm.position.x)
		if i != _selected:
			_selected = i
			_update_fields()
		_paint(mm.position)

func _paint(pos: Vector2) -> void:
	var pr := _plot()
	var i := _slot_at(pos.x)
	var amp: float = 0.0
	if _stroke_button == MOUSE_BUTTON_LEFT:
		amp = snappedf(clampf((pr.end.y - pos.y) / pr.size.y, 0.0, 1.0), 0.01)
	# Packed arrays are passed by reference: edit a copy, so the patch's own array
	# (and the undo action's "old") stay as they were until the setter runs.
	var arr: PackedFloat32Array = patch.harmonics.duplicate()
	if i >= arr.size():
		if amp == 0.0:
			return
		arr.resize(i + 1)  # new partials start at 0
	if arr[i] == amp:
		return
	arr[i] = amp
	live.emit(&"harmonics", arr)
	_amp_spin.set_value_no_signal(amp)
	_bars.queue_redraw()

func _tooltip_for(i: int) -> String:
	var ratio: float = _ratio_at(i)
	return "Partial %d: amplitude %.2f, ratio %s" % [i + 1, _amp_at(i),
			("x%.2f" % ratio) if ratio > 0.0 else ("x%d (integer)" % (i + 1))]

func _on_amp_field(v: float) -> void:
	if patch == null:
		return
	var old: PackedFloat32Array = patch.harmonics.duplicate()
	var arr: PackedFloat32Array = old.duplicate()
	if _selected >= arr.size():
		if v == 0.0:
			return
		arr.resize(_selected + 1)
	arr[_selected] = v
	committed.emit(&"harmonics", arr, old)

func _on_ratio_field(v: float) -> void:
	if patch == null:
		return
	var old: PackedFloat32Array = patch.harmonic_ratios.duplicate()
	var arr: PackedFloat32Array = old.duplicate()
	if _selected >= arr.size():
		if v == 0.0:
			return
		arr.resize(_selected + 1)
	arr[_selected] = v
	# Missing and trailing zeros mean "integer multiple" already.
	while arr.size() > 0 and arr[arr.size() - 1] == 0.0:
		arr.remove_at(arr.size() - 1)
	if arr != old:
		committed.emit(&"harmonic_ratios", arr, old)

func _on_count_field(v: float) -> void:
	if patch == null:
		return
	_slots = clampi(int(v), 1, MAX_SLOTS)
	var old: PackedFloat32Array = patch.harmonics.duplicate()
	if old.size() > _slots:
		var arr: PackedFloat32Array = old.duplicate()
		arr.resize(_slots)
		committed.emit(&"harmonics", arr, old)
	_selected = clampi(_selected, 0, _slots - 1)
	_update_fields()
	_bars.queue_redraw()
