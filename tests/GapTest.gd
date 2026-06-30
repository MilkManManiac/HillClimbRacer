extends Node
## Headless logic check for the gap/checkpoint carving. No rendering — just verifies
## _gap_for_z + height_at produce a ramp -> void -> flat-landing profile on the road,
## leave the sides untouched, and keep pure hills before the first gap.

const HCTerrainScript := preload("res://scripts/hc/HCTerrain.gd")

func _ready() -> void:
	var t := Node3D.new()
	t.set_script(HCTerrainScript)
	add_child(t)
	var fails := 0

	# 1) pure hills well before the first gap
	var g_early: Dictionary = t.call("_gap_for_z", -100.0)
	if not g_early.is_empty():
		print("[gap] FAIL: gap reported at d=100 (before gap_start_dist)"); fails += 1

	# 2) first gap resolves and its features sit at the right distances
	var gap0_center_z: float = -float(t.get("gap_start_dist"))   # idx 0 center
	var g: Dictionary = t.call("_gap_for_z", gap0_center_z)
	if g.is_empty():
		print("[gap] FAIL: no gap at first center"); fails += 1
	else:
		var lvl: float = g.level
		# void floor sits well below the gap table level
		var hy_void: float = t.call("height_at", 0.0, float(g.center_z))
		if hy_void > lvl - 20.0:
			print("[gap] FAIL: void not carved (h=%.1f, level=%.1f)" % [hy_void, lvl]); fails += 1
		# ramp rises above the table level toward the lip
		var hy_ramp: float = t.call("height_at", 0.0, float(g.lip_z) + 2.0)
		if hy_ramp <= lvl + 1.0:
			print("[gap] FAIL: ramp does not kick up (ramp=%.1f level=%.1f)" % [hy_ramp, lvl]); fails += 1
		# landing platform is flat at the table level just past the far edge
		var hy_land: float = t.call("height_at", 0.0, float(g.far_z) - 6.0)
		if absf(hy_land - lvl) > 1.5:
			print("[gap] FAIL: landing not at table level (land=%.2f level=%.2f)" % [hy_land, lvl]); fails += 1
		# THE KEY ONE: takeoff and landing must be at (nearly) the same height
		var hy_takeoff: float = t.call("height_at", 0.0, float(g.ramp_z0) + 9.0)   # approach plateau
		if absf(hy_takeoff - hy_land) > 2.5:
			print("[gap] FAIL: takeoff/landing height mismatch (takeoff=%.2f land=%.2f)" % [hy_takeoff, hy_land]); fails += 1
		# the SIDES (off road) must NOT be carved into the void
		var side_x: float = t.get("road_half_width") + t.get("edge_falloff") + 8.0
		var hy_side: float = t.call("height_at", side_x, float(g.center_z))
		if hy_side < lvl - 20.0:
			print("[gap] FAIL: void carved off-road (side h=%.1f)" % hy_side); fails += 1

	# 3) ramp and landing of the same gap map to the same idx (the round() fix)
	if not g.is_empty():
		var gr: Dictionary = t.call("_gap_for_z", float(g.ramp_z0) - 1.0)
		var gl: Dictionary = t.call("_gap_for_z", float(g.far_z) - 5.0)
		if gr.is_empty() or gl.is_empty() or int(gr.idx) != int(g.idx) or int(gl.idx) != int(g.idx):
			print("[gap] FAIL: ramp/landing split across gap indices"); fails += 1

	if fails == 0:
		print("[gap] OK — all carve/detect checks passed")
	else:
		print("[gap] %d CHECK(S) FAILED" % fails)
	get_tree().quit()
