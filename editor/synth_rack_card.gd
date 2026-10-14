@tool
class_name SynthRackCard
extends PanelContainer

# One module of the patch rack: a title, a small tag, and a body of graph, controls
# and parameter rows. A card can be dimmed (the module does nothing right now) and
# stays fully usable while dimmed, so editing a dimmed card is how to switch it on.

var body: VBoxContainer
var _title: Label
var _tag: Label
var _tag_box: PanelContainer

func _init(title: String = "", tag: String = "") -> void:
	# PASS, not STOP: a click on a card's empty space reaches the rack and
	# focuses it, which is what makes the A-K keys play (see SynthPatchRack).
	mouse_filter = Control.MOUSE_FILTER_PASS
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	root.add_child(head)
	_title = Label.new()
	_title.text = title
	_title.add_theme_font_size_override("font_size", 15)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_tag_box = PanelContainer.new()
	_tag_box.mouse_filter = Control.MOUSE_FILTER_PASS
	_tag_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tag = Label.new()
	_tag.text = tag
	_tag.add_theme_font_size_override("font_size", 11)
	_tag_box.add_child(_tag)
	_tag_box.visible = tag != ""
	head.add_child(_tag_box)

	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	root.add_child(body)

func _ready() -> void:
	_restyle()

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_restyle()

# Setting a theme override notifies THEME_CHANGED again, hence the guard.
var _restyling: bool = false

func _restyle() -> void:
	if _tag_box == null or _restyling:
		return
	_restyling = true
	add_theme_stylebox_override("panel", SynthRackStyle.make_card_style(self))
	var s := SynthRackStyle.scale(self)
	var sb := StyleBoxFlat.new()
	sb.bg_color = SynthRackStyle.inset(self)
	sb.set_corner_radius_all(roundi(8 * s))
	sb.content_margin_left = 7 * s
	sb.content_margin_right = 7 * s
	sb.content_margin_top = 1 * s
	sb.content_margin_bottom = 1 * s
	_tag_box.add_theme_stylebox_override("panel", sb)
	_tag.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_restyling = false

func set_dimmed(dimmed: bool) -> void:
	modulate = Color(1, 1, 1, 0.5) if dimmed else Color.WHITE

func add_section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	body.add_child(l)
	return l
