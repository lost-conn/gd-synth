@tool
class_name SynthRackGraph
extends Control

# The small live pictures on the patch rack's cards. One class, one _draw per
# Kind, all of them cheap and all redrawn only when refresh() is called (the rack
# calls it on an edit; nothing here animates).
#
#   WAVE      one cycle of the patch's wavetable
#   ENVELOPE  the ADSR curve (amp, or the filter's when env_prefix is "filter_")
#   FILTER    the filter's frequency response
#   FM        two carrier cycles with the FM modulation applied
#   PITCH     the pitch-drop curve: semitones above the note over time
#   NOISE     the noise source's spectrum after its low- and high-pass
#
# These are illustrations of the patch's numbers, not renders of the engine: see
# the notes on FILTER and NOISE for where they approximate.

enum Kind { WAVE, ENVELOPE, FILTER, FM, PITCH, NOISE }

var kind: int = Kind.WAVE
var patch: SynthPatch
## ENVELOPE: "" for the amp envelope, "filter_" for the filter's.
var env_prefix: String = ""
## Height at editor scale 1.
var base_height: float = 64.0

# The noise source's rate: the live engine's, whose per-sample one-pole filters
# the noise_lowpass / noise_highpass coefficients are defined at.
const NOISE_RATE := 22050.0

func _init(p_kind: int = Kind.WAVE, p_height: float = 64.0) -> void:
	kind = p_kind
	base_height = p_height
	mouse_filter = Control.MOUSE_FILTER_PASS

func _ready() -> void:
	custom_minimum_size = Vector2(0, base_height * SynthRackStyle.scale(self))

func set_patch(p: SynthPatch) -> void:
	patch = p
	queue_redraw()

func refresh() -> void:
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()

# ---------------------------------------------------------------------------

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, SynthRackStyle.inset(self))
	if patch == null or size.x < 8.0 or size.y < 8.0:
		return
	match kind:
		Kind.WAVE:
			_draw_wave()
		Kind.ENVELOPE:
			_draw_envelope()
		Kind.FILTER:
			_draw_filter()
		Kind.FM:
			_draw_fm()
		Kind.PITCH:
			_draw_pitch()
		Kind.NOISE:
			_draw_noise()
	draw_rect(r, SynthRackStyle.grid(self), false, 1.0)

func _plot_rect() -> Rect2:
	var pad: float = 6.0 * SynthRackStyle.scale(self)
	return Rect2(pad, pad, size.x - 2.0 * pad, size.y - 2.0 * pad)

func _caption(txt: String, at_right: bool = false, at_bottom: bool = false) -> void:
	var f := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.8)
	var pad: float = 5.0 * SynthRackStyle.scale(self)
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := size.x - w - pad if at_right else pad
	var y := size.y - pad - f.get_descent(fs) if at_bottom else pad + f.get_ascent(fs)
	draw_string(f, Vector2(x, y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SynthRackStyle.dim(self))

func _fill_and_line(pts: PackedVector2Array, baseline: float) -> void:
	if pts.size() < 2:
		return
	var acc := SynthRackStyle.accent(self)
	var poly := PackedVector2Array()
	var raw := PackedVector2Array(pts)
	raw.append(Vector2(pts[pts.size() - 1].x, baseline))
	raw.append(Vector2(pts[0].x, baseline))
	# No repeated neighbours: the triangulator rejects them.
	for v in raw:
		if poly.is_empty() or poly[poly.size() - 1].distance_to(v) > 0.01:
			poly.append(v)
	if poly.size() > 1 and poly[0].distance_to(poly[poly.size() - 1]) <= 0.01:
		poly.remove_at(poly.size() - 1)
	var fill := acc
	fill.a = 0.2
	if _poly_ok(poly):
		draw_colored_polygon(poly, fill)
	draw_polyline(pts, acc, maxf(1.5, 1.5 * SynthRackStyle.scale(self)), true)

# draw_colored_polygon logs an error for a polygon it cannot triangulate.
func _poly_ok(poly: PackedVector2Array) -> bool:
	if poly.size() < 3:
		return false
	var area := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		area += a.x * b.y - b.x * a.y
	return absf(area) > 0.5 and not Geometry2D.triangulate_polygon(poly).is_empty()

# --- WAVE -------------------------------------------------------------------

func _draw_wave() -> void:
	var pr := _plot_rect()
	var mid := pr.position.y + pr.size.y * 0.5
	draw_line(Vector2(pr.position.x, mid), Vector2(pr.end.x, mid), SynthRackStyle.grid(self), 1.0)
	var n: int = clampi(int(pr.size.x / 2.0), 16, 256)
	var pts := PackedVector2Array()
	for i in n + 1:
		var ph: float = float(i) / float(n)
		var v: float = patch.sample(minf(ph, 0.99999))
		pts.append(Vector2(pr.position.x + ph * pr.size.x, mid - v * pr.size.y * 0.5))
	draw_polyline(pts, SynthRackStyle.accent(self), maxf(1.5, 1.5 * SynthRackStyle.scale(self)), true)

# --- ENVELOPE ---------------------------------------------------------------

func _draw_envelope() -> void:
	var a: float = maxf(float(patch.get(env_prefix + "attack")), 0.0)
	var d: float = maxf(float(patch.get(env_prefix + "decay")), 0.0)
	var s: float = clampf(float(patch.get(env_prefix + "sustain")), 0.0, 1.0)
	var r: float = maxf(float(patch.get(env_prefix + "release")), 0.0)
	# The held plateau has no length of its own; draw it about a third of the rest.
	var hold: float = maxf((a + d + r) * 0.35, 0.05)
	var times: Array[float] = [a, d, hold, r]
	var sum: float = a + d + hold + r
	# Every segment gets at least a sliver, so a 0 s attack is still a visible edge.
	var frac: Array[float] = []
	var total_frac := 0.0
	for t in times:
		var f: float = maxf(t / sum, 0.05)
		frac.append(f)
		total_frac += f
	var pr := _plot_rect()
	var top: float = pr.position.y + 12.0 * SynthRackStyle.scale(self)
	var base: float = pr.end.y
	var h: float = base - top
	var x: float = pr.position.x
	var xs: Array[float] = [x]
	for f in frac:
		x += pr.size.x * f / total_frac
		xs.append(x)
	var pts := PackedVector2Array([
		Vector2(xs[0], base),
		Vector2(xs[1], top),
		Vector2(xs[2], base - s * h),
		Vector2(xs[3], base - s * h),
		Vector2(xs[4], base),
	])
	# Segment boundaries and their letters.
	var grid := SynthRackStyle.grid(self)
	var fnt := SynthRackStyle.font(self)
	var fs := SynthRackStyle.font_size(self, 0.75)
	var letters := ["A", "D", "S", "R"]
	for i in 4:
		if i > 0:
			draw_line(Vector2(xs[i], top), Vector2(xs[i], base), grid, 1.0)
		var cx: float = (xs[i] + xs[i + 1]) * 0.5
		var w: float = fnt.get_string_size(letters[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(fnt, Vector2(cx - w * 0.5, pr.position.y + fnt.get_ascent(fs) - 2.0), letters[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SynthRackStyle.dim(self))
	_fill_and_line(pts, base)
	_caption("%s s" % _fmt_time(a + d + r), true, true)

static func _fmt_time(t: float) -> String:
	if t >= 10.0:
		return "%.0f" % t
	if t >= 1.0:
		return "%.2f" % t
	return "%.3f" % t

# --- FILTER -----------------------------------------------------------------
#
# Approximation: the analog 2-pole state-variable response with the engine's own
# cutoff mapping (20 Hz * 1000^cutoff) and resonance mapping (Q = 0.5 + res^2 *
# 19.5). The engine's filter is the digital (bilinear) form of that, which
# agrees below roughly a fifth of the sample rate and bends away from it near
# Nyquist; the curve is a guide to the shape, not a measurement.

const FILTER_DB_TOP := 30.0
const FILTER_DB_BOTTOM := -36.0

static func filter_gain_db(type: int, f: float, cutoff_norm: float, resonance: float) -> float:
	var fc: float = 20.0 * pow(1000.0, clampf(cutoff_norm, 0.0, 1.0))
	var q: float = 0.5 + resonance * resonance * 19.5
	var k: float = 1.0 / q
	var x: float = f / fc
	var x2: float = x * x
	var den: float = sqrt((1.0 - x2) * (1.0 - x2) + k * k * x2)
	var g: float = 1.0
	match type:
		SynthPatch.FilterType.LOWPASS:
			g = 1.0 / den
		SynthPatch.FilterType.HIGHPASS:
			g = x2 / den
		SynthPatch.FilterType.BANDPASS:
			g = x / den
	return 20.0 * log(maxf(g, 1e-6)) / log(10.0)

func _db_y(pr: Rect2, db: float) -> float:
	var t: float = (FILTER_DB_TOP - clampf(db, FILTER_DB_BOTTOM, FILTER_DB_TOP)) / (FILTER_DB_TOP - FILTER_DB_BOTTOM)
	return pr.position.y + t * pr.size.y

func _response_points(pr: Rect2, type: int, cutoff_norm: float, resonance: float) -> PackedVector2Array:
	var n: int = clampi(int(pr.size.x / 2.0), 24, 256)
	var pts := PackedVector2Array()
	for i in n + 1:
		var t: float = float(i) / float(n)
		var f: float = 20.0 * pow(1000.0, t)
		pts.append(Vector2(pr.position.x + t * pr.size.x, _db_y(pr, filter_gain_db(type, f, cutoff_norm, resonance))))
	return pts

func _draw_filter() -> void:
	var pr := _plot_rect()
	var grid := SynthRackStyle.grid(self)
	# 0 dB line, and decade lines at 100 Hz, 1 kHz, 10 kHz.
	var y0 := _db_y(pr, 0.0)
	draw_line(Vector2(pr.position.x, y0), Vector2(pr.end.x, y0), grid, 1.0)
	for f in [100.0, 1000.0, 10000.0]:
		var gx: float = pr.position.x + log(f / 20.0) / log(1000.0) * pr.size.x
		draw_line(Vector2(gx, pr.position.y), Vector2(gx, pr.end.y), grid, 1.0)
	var type: int = patch.filter_type
	if type == SynthPatch.FilterType.OFF:
		draw_line(Vector2(pr.position.x, y0), Vector2(pr.end.x, y0), SynthRackStyle.dim(self), 1.5)
		_caption("filter off")
		return
	var acc := SynthRackStyle.accent(self)
	# Where the envelope sweeps the cutoff to (peak of the filter envelope).
	if absf(patch.filter_env_amount) > 0.001:
		var swept: float = clampf(patch.filter_cutoff + patch.filter_env_amount, 0.0, 1.0)
		var ghost := acc
		ghost.a = 0.35
		draw_polyline(_response_points(pr, type, swept, patch.filter_resonance), ghost, 1.0, true)
	var pts := _response_points(pr, type, patch.filter_cutoff, patch.filter_resonance)
	_fill_and_line(pts, pr.end.y)
	var cx: float = pr.position.x + clampf(patch.filter_cutoff, 0.0, 1.0) * pr.size.x
	draw_line(Vector2(cx, pr.position.y), Vector2(cx, pr.end.y), SynthRackStyle.dim(self), 1.0)
	var fc: float = 20.0 * pow(1000.0, clampf(patch.filter_cutoff, 0.0, 1.0))
	_caption("%s Hz" % ("%.0f" % fc if fc < 1000.0 else "%.1fk" % (fc / 1000.0)).replace(".0k", "k"), true)

# --- FM ---------------------------------------------------------------------
# Two carrier cycles of the patch's own waveform, phase-modulated the way the
# engine does it: the modulator is a sine at fm_ratio times the carrier and adds
# fm_index cycles of phase.

func _draw_fm() -> void:
	var pr := _plot_rect()
	var mid := pr.position.y + pr.size.y * 0.5
	draw_line(Vector2(pr.position.x, mid), Vector2(pr.end.x, mid), SynthRackStyle.grid(self), 1.0)
	var n: int = clampi(int(pr.size.x), 32, 400)
	var pts := PackedVector2Array()
	var idx: float = maxf(patch.fm_index, 0.0)
	for i in n + 1:
		var t: float = 2.0 * float(i) / float(n)
		var ph: float = fposmod(t + idx * sin(TAU * patch.fm_ratio * t), 1.0)
		pts.append(Vector2(pr.position.x + t * 0.5 * pr.size.x, mid - patch.sample(ph) * pr.size.y * 0.5))
	var acc := SynthRackStyle.accent(self)
	if idx <= 0.0:
		acc.a = 0.55
	draw_polyline(pts, acc, maxf(1.5, 1.5 * SynthRackStyle.scale(self)), true)
	if idx <= 0.0:
		_caption("FM off (index 0)")

# --- PITCH ------------------------------------------------------------------
# The engine's pitch envelope is linear in semitones: the voice starts
# pitch_decay_semitones above the note and falls to it over pitch_decay_time.

func _draw_pitch() -> void:
	var pr := _plot_rect()
	var st: float = patch.pitch_decay_semitones
	var tm: float = patch.pitch_decay_time
	var top: float = pr.position.y + 12.0 * SynthRackStyle.scale(self)
	var base: float = pr.end.y
	draw_line(Vector2(pr.position.x, base), Vector2(pr.end.x, base), SynthRackStyle.grid(self), 1.0)
	if st <= 0.0 or tm <= 0.0:
		draw_line(Vector2(pr.position.x, base), Vector2(pr.end.x, base), SynthRackStyle.dim(self), 1.5)
		_caption("no pitch drop")
		return
	var knee: float = pr.position.x + pr.size.x * 0.7
	var pts := PackedVector2Array([
		Vector2(pr.position.x, top),
		Vector2(knee, base),
		Vector2(pr.end.x, base),
	])
	_fill_and_line(pts, base)
	_caption("+%s st over %s s" % [("%.1f" % st).trim_suffix(".0"), _fmt_time(tm)])

# --- NOISE ------------------------------------------------------------------
# The noise source is white noise through a one-pole low-pass (noise_lowpass is
# its coefficient) and then a one-pole high-pass made by subtracting a second
# one-pole low-pass (noise_highpass). Drawn is the cascade's magnitude on a log
# frequency axis up to the engine's Nyquist, lowered by noise_mix. The one-poles
# are evaluated exactly (z = e^jw), so this one is a measurement, not a guess;
# the engine's noise_mix crossfades noise against the oscillator and noise_decay
# fades it over time, neither of which is a spectrum, so they are not drawn.

const NOISE_DB_TOP := 6.0
const NOISE_DB_BOTTOM := -48.0
const NOISE_F_LOW := 40.0

static func noise_gain_db(f: float, lowpass: float, highpass: float) -> float:
	var w: float = TAU * f / NOISE_RATE
	var g: float = 1.0
	if lowpass < 1.0:
		g *= _onepole_lp(w, lowpass).length()
	if highpass > 0.0:
		var h := _onepole_lp(w, highpass)
		g *= Vector2(1.0 - h.x, -h.y).length()
	return 20.0 * log(maxf(g, 1e-6)) / log(10.0)

# H(z) = c / (1 - (1 - c) z^-1) at z = e^jw, as (re, im).
static func _onepole_lp(w: float, c: float) -> Vector2:
	var a: float = 1.0 - c
	var den := Vector2(1.0 - a * cos(w), a * sin(w))
	var d2: float = den.length_squared()
	if d2 <= 1e-12:
		return Vector2(1.0, 0.0)
	return Vector2(c * den.x / d2, -c * den.y / d2)

func _draw_noise() -> void:
	var pr := _plot_rect()
	var mix: float = clampf(patch.noise_mix, 0.0, 1.0)
	var grid := SynthRackStyle.grid(self)
	for f in [100.0, 1000.0, 10000.0]:
		var gx: float = pr.position.x + log(f / NOISE_F_LOW) / log(NOISE_RATE * 0.5 / NOISE_F_LOW) * pr.size.x
		draw_line(Vector2(gx, pr.position.y), Vector2(gx, pr.end.y), grid, 1.0)
	if mix <= 0.0:
		draw_line(Vector2(pr.position.x, pr.end.y), Vector2(pr.end.x, pr.end.y), SynthRackStyle.dim(self), 1.5)
		_caption("no noise")
		return
	var mix_db: float = 20.0 * log(mix) / log(10.0)
	var n: int = clampi(int(pr.size.x / 2.0), 24, 256)
	var pts := PackedVector2Array()
	var span: float = log(NOISE_RATE * 0.5 / NOISE_F_LOW)
	for i in n + 1:
		var t: float = float(i) / float(n)
		var f: float = NOISE_F_LOW * exp(t * span)
		var db: float = noise_gain_db(f, patch.noise_lowpass, patch.noise_highpass) + mix_db
		var yt: float = (NOISE_DB_TOP - clampf(db, NOISE_DB_BOTTOM, NOISE_DB_TOP)) / (NOISE_DB_TOP - NOISE_DB_BOTTOM)
		pts.append(Vector2(pr.position.x + t * pr.size.x, pr.position.y + yt * pr.size.y))
	_fill_and_line(pts, pr.end.y)
	_caption("spectrum", true)
