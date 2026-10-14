@tool
class_name SynthRackStyle
extends RefCounted

# Colours, sizes and fonts for the Sound view's custom widgets. Everything comes
# from the editor theme when the view runs inside the editor (it inherits the
# editor theme, so Control.get_theme_color("accent_color", "Editor") resolves),
# and falls back to a dark palette anywhere else.

## Editor UI scale (EDSCALE). 1.0 outside the editor.
static func scale(c: Control) -> float:
	return c.get_theme_default_base_scale() if c != null else 1.0

static func accent(c: Control) -> Color:
	if c.has_theme_color("accent_color", "Editor"):
		return c.get_theme_color("accent_color", "Editor")
	return Color(0.34, 0.62, 1.0)

## Second accent for "this is what the game plays" markers.
static func marker(_c: Control) -> Color:
	return Color(1.0, 0.78, 0.3)

static func text(c: Control) -> Color:
	if c.has_theme_color("font_color", "Label"):
		return c.get_theme_color("font_color", "Label")
	return Color(0.88, 0.89, 0.92)

static func dim(c: Control) -> Color:
	var t := text(c)
	t.a = 0.55
	return t

static func grid(c: Control) -> Color:
	var t := text(c)
	t.a = 0.13
	return t

## Background of the little graphs and of recessed areas.
static func inset(c: Control) -> Color:
	if c.has_theme_color("dark_color_2", "Editor"):
		return c.get_theme_color("dark_color_2", "Editor")
	return Color(0.1, 0.11, 0.13)

## Background of a module card.
static func card_bg(c: Control) -> Color:
	if c.has_theme_color("dark_color_1", "Editor"):
		return c.get_theme_color("dark_color_1", "Editor")
	return Color(0.14, 0.15, 0.18)

static func card_border(c: Control) -> Color:
	if c.has_theme_color("contrast_color_1", "Editor"):
		var b := c.get_theme_color("contrast_color_1", "Editor")
		b.a = 0.5
		return b
	return Color(1, 1, 1, 0.08)

static func good(_c: Control) -> Color:
	return Color(0.45, 0.82, 0.52)

static func warn(_c: Control) -> Color:
	return Color(1.0, 0.72, 0.28)

static func font(c: Control) -> Font:
	return c.get_theme_default_font()

static func font_size(c: Control, factor: float = 1.0) -> int:
	return maxi(8, roundi(c.get_theme_default_font_size() * factor))

static func make_card_style(c: Control) -> StyleBoxFlat:
	var s := scale(c)
	var sb := StyleBoxFlat.new()
	sb.bg_color = card_bg(c)
	sb.border_color = card_border(c)
	sb.set_border_width_all(maxi(1, roundi(s)))
	sb.set_corner_radius_all(roundi(4 * s))
	sb.content_margin_left = 10 * s
	sb.content_margin_right = 10 * s
	sb.content_margin_top = 8 * s
	sb.content_margin_bottom = 10 * s
	return sb

## "C4" for midi 60.
static func note_name(midi: int) -> String:
	const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [NAMES[posmod(midi, 12)], floori(midi / 12.0) - 1]
