extends SceneTree

# Runs every test file of this folder and exits non-zero if any check failed:
#
#   godot --headless --path <project> -s res://addons/godot_synth/tests/run_all.gd
#
# A test file extends test_util.gd and has a run(tree) method (it may await). It
# uses in-memory resources only; what it must write goes under user:// and is removed.
# Arguments after "--" pick files by name: ... run_all.gd -- smoke song_view

const DIR := "res://addons/godot_synth/tests/"
const FILES := ["test_smoke.gd", "test_song_view.gd"]
# A test that has not finished in this many seconds has hung (a script error aborts
# its coroutine and nothing else would end the run).
const TIMEOUT := 120.0

var _failed: int = 0
var _checks: int = 0
var _done: bool = false

func _initialize() -> void:
	var only: Array = []
	var args := OS.get_cmdline_user_args()
	for a in args:
		only.append(a)
	var timer := create_timer(TIMEOUT)
	timer.timeout.connect(_on_timeout)
	var t0 := Time.get_ticks_msec()
	# Nodes added to root during _initialize are not in the tree until the first frame.
	await process_frame
	for f in FILES:
		if not only.is_empty() and not only.any(func(o): return f.contains(o)):
			continue
		var script := load(DIR + f) as GDScript
		if script == null or not script.can_instantiate():
			print("FAIL  %s: does not load" % f)
			_failed += 1
			continue
		var tc = script.new()
		await tc.run(self)
		_checks += tc.checks
		var bad: PackedStringArray = tc.failures
		print("%s  %s: %d checks, %d failed" % ["ok  " if bad.is_empty() else "FAIL", f, tc.checks, bad.size()])
		for b in bad:
			print("      " + b)
		_failed += bad.size()
	_done = true
	print("%d checks, %d failed, %.1f s" % [_checks, _failed, float(Time.get_ticks_msec() - t0) / 1000.0])
	quit(1 if _failed > 0 else 0)

func _on_timeout() -> void:
	if _done:
		return
	print("FAIL  timed out after %.0f s (a test hung, or a script error aborted it)" % TIMEOUT)
	quit(2)
