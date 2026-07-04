extends RefCounted
## Car-child visual FX for HCCar (A3: world-parented skids + shed panels stay on the car).

# NOTE: deliberate preload cycle with HCCar (it preloads this file). Verified fine
# on Godot 4.6.3 — and the typed `car` is what lets `:=` inference work below.
const HCCarScript := preload("res://scripts/hc/HCCar.gd")

var car: HCCarScript

func _init(host: HCCarScript) -> void:
	car = host

func build() -> void:
	_build_dust()
	_build_smoke()
	_build_wind()
	_build_underglow()

## Landing dust puffs (called from HCCar._on_land).
func on_land(impact: float, air_time: float, puff_pos: Vector3) -> void:
	if air_time <= 0.3:
		return
	if impact > 8.0 and car._dust_big:
		car._dust_big.global_position = puff_pos
		car._dust_big.restart()
		if car._ring_puff:
			car._ring_puff.global_position = puff_pos
			car._ring_puff.restart()
	elif car._dust:
		car._dust.global_position = puff_pos
		car._dust.restart()

## Per-frame smoke / wind / damage / backfire updates (from _physics_process).
func tick(delta: float, drive: float, speed: float) -> void:
	var speed_k: float = clampf(speed / car.max_speed, 0.0, 1.0)
	for i in range(car._tire_smoke.size()):
		var ts := car._tire_smoke[i]
		ts.emitting = car.drifting and car._grounded
		var wi: int = i + 2   # rear wheels are _wheel_meshes indices 2, 3
		if wi < car._wheel_meshes.size():
			ts.global_position = car._wheel_meshes[wi].global_position
		var tpm := ts.process_material as ParticleProcessMaterial
		if tpm:
			tpm.initial_velocity_min = 0.8 + speed_k * 1.4
			tpm.initial_velocity_max = 2.4 + speed_k * 3.0
	var puffing: bool = (drive > 0.05 and car.fuel > 0.0) or car.boosting
	for es in car._exhaust_smoke:
		es.emitting = puffing
	if car._wind_streaks:
		car._wind_streaks.emitting = speed > car.max_speed * 0.6
	if car._damage_smoke:
		car._damage_smoke.emitting = car.health < car.max_health * 0.5
	car._backfire_cd = maxf(car._backfire_cd - delta, 0.0)
	if car._prev_drive > 0.55 and drive < 0.15 and speed > 8.0 and car._grounded and car._backfire_cd <= 0.0:
		for bf in car._backfire:
			bf.restart()
		car._backfire_cd = 0.5
	car._prev_drive = drive

func apply_underglow(on: bool, color: Color) -> void:
	if car._underglow == null:
		return
	car._underglow.visible = on
	if not on:
		return
	for mi in car._ug_strips:
		var m := mi.material_override as StandardMaterial3D
		m.albedo_color = color
		m.emission = color
	if car._ug_light:
		car._ug_light.light_color = color

func apply_smoke_color(color: Color) -> void:
	var core := Color(color.r, color.g, color.b, 0.55)
	var edge := Color(color.r, color.g, color.b, 0.0)
	for ts in car._tire_smoke:
		_retint(ts, core, edge)

func apply_flame_color(color: Color) -> void:
	var core := color.lerp(Color(1, 1, 1, 1), 0.55); core.a = 1.0
	var edge := Color(color.r, color.g, color.b, 0.0)
	for f in car._rocket_flames:
		_retint(f, core, edge)

func _build_underglow() -> void:
	car._underglow = Node3D.new()
	car.add_child(car._underglow)
	var hx: float = float(car._vs.fx) + 0.05
	var hz: float = float(car._vs.fz) + 0.3
	var y := 0.12
	var strips := [
		[Vector3(0, y, -hz), Vector3(hx * 2.0, 0.05, 0.14)],   # front
		[Vector3(0, y, hz), Vector3(hx * 2.0, 0.05, 0.14)],    # rear
		[Vector3(-hx, y, 0), Vector3(0.14, 0.05, hz * 2.0)],   # left
		[Vector3(hx, y, 0), Vector3(0.14, 0.05, hz * 2.0)],    # right
	]
	for st in strips:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = st[1]
		mi.mesh = bm
		mi.position = st[0]
		var m := StandardMaterial3D.new()
		m.emission_enabled = true
		m.emission_energy_multiplier = 3.0
		mi.material_override = m
		car._underglow.add_child(mi)
		car._ug_strips.append(mi)
	car._ug_light = OmniLight3D.new()
	car._ug_light.position = Vector3(0, 0.05, 0)
	car._ug_light.omni_range = 4.5
	car._ug_light.light_energy = 2.2
	car._underglow.add_child(car._ug_light)
	car._underglow.visible = false
func _retint(p: GPUParticles3D, core: Color, edge: Color) -> void:
	if p == null:
		return
	var pm := p.process_material as ParticleProcessMaterial
	if pm == null:
		return
	var grad := Gradient.new()
	grad.set_color(0, core)
	grad.set_color(1, edge)
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
func _make_dust(amount: int, life: float, vmin: float, vmax: float, spread: float, smin: float, smax: float, alpha: float) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.amount = amount
	g.lifetime = life
	g.one_shot = true
	g.emitting = false
	g.explosiveness = 0.85
	g.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = spread
	pm.gravity = Vector3(0, -3, 0)
	pm.initial_velocity_min = vmin
	pm.initial_velocity_max = vmax
	pm.scale_min = smin
	pm.scale_max = smax
	g.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.5, 0.5)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.62, 0.57, 0.47, alpha)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.material = dm
	g.draw_pass_1 = qm
	car.add_child(g)
	return g
func _build_dust() -> void:
	car._dust = _make_dust(24, 0.6, 1.5, 3.5, 65.0, 0.4, 1.0, 0.6)          # soft touchdown
	car._dust_big = _make_dust(46, 0.95, 3.0, 6.0, 72.0, 0.75, 1.7, 0.72)   # hard impact
	_build_ring_puff()
	# small, subtle pop at a panel's spot the instant it detaches — reuses the same
	# dust-puff shape/material as landings, just tiny, so it doesn't need its own asset.
	car._panel_pop = _make_dust(10, 0.4, 1.0, 2.4, 55.0, 0.12, 0.3, 0.5)
func _build_ring_puff() -> void:
	car._ring_puff = GPUParticles3D.new()
	car._ring_puff.amount = 22
	car._ring_puff.lifetime = 0.4
	car._ring_puff.one_shot = true
	car._ring_puff.emitting = false
	car._ring_puff.explosiveness = 1.0
	car._ring_puff.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.35
	pm.emission_ring_inner_radius = 0.15
	pm.emission_ring_height = 0.05
	pm.direction = Vector3(0, 0.1, 0)
	pm.spread = 6.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.3
	pm.radial_accel_min = 7.0
	pm.radial_accel_max = 10.0
	pm.gravity = Vector3(0, -2.0, 0)
	pm.scale_min = 0.8
	pm.scale_max = 1.4
	car._ring_puff.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.4, 0.4)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.66, 0.6, 0.5, 0.5)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.material = dm
	car._ring_puff.draw_pass_1 = qm
	car.add_child(car._ring_puff)
func _make_smoke(col: Color, smin: float, smax: float, vmin: float, vmax: float, dir: Vector3, amount: int, life: float, grav: float, growth_end: float = 1.0) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.amount = amount
	g.lifetime = life
	g.emitting = false
	g.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir
	pm.spread = 35.0
	pm.initial_velocity_min = vmin
	pm.initial_velocity_max = vmax
	pm.gravity = Vector3(0, grav, 0)
	pm.scale_min = smin
	pm.scale_max = smax
	var grad := Gradient.new()
	grad.set_color(0, Color(col.r, col.g, col.b, col.a))
	grad.set_color(1, Color(col.r, col.g, col.b, 0.0))   # fade to clear
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	# growth_end > 1.0 lets a puff keep billowing bigger over its life (tire smoke),
	# instead of just holding its spawn size (exhaust/damage/backfire default).
	var curve := Curve.new(); curve.add_point(Vector2(0, 0.35)); curve.add_point(Vector2(1, growth_end))
	var ct := CurveTexture.new(); ct.curve = curve
	pm.scale_curve = ct
	g.process_material = pm
	var qm := QuadMesh.new(); qm.size = Vector2(1, 1)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1, 1, 1)
	qm.material = m
	g.draw_pass_1 = qm
	return g
func _build_smoke() -> void:
	# tire smoke off the two rear wheels (shown while drifting) — warm grey, dense,
	# billows bigger the longer it lives (growth_end 1.6), and its initial velocity
	# gets re-tuned live by current speed in _physics_process.
	for i in [2, 3]:
		if i >= car._wheel_positions.size():
			continue
		var p: Vector3 = car._wheel_positions[i]
		var sm := _make_smoke(Color(0.72, 0.68, 0.62, 0.6), 0.6, 1.8, 1.0, 2.6, Vector3(0, 1, 0), 46, 1.15, 0.55, 1.6)
		sm.position = Vector3(p.x, 0.12, p.z)
		car.add_child(sm)
		car._tire_smoke.append(sm)
	# exhaust smoke — dark diesel stacks for the monster, light puffs for the hot-rod
	if car.vehicle_type == "monster":
		for sx in [-1.16, 1.16]:
			var e := _make_smoke(Color(0.13, 0.13, 0.14, 0.75), 0.45, 1.1, 0.8, 1.8, Vector3(0, 1, 0), 26, 0.7, 2.2)
			e.position = Vector3(sx, 2.8, 0.3)
			car.add_child(e)
			car._exhaust_smoke.append(e)
	else:
		for sx in [-0.45, 0.45]:
			var e := _make_smoke(Color(0.42, 0.42, 0.45, 0.5), 0.22, 0.7, 1.2, 2.8, Vector3(0, 0.4, 1), 18, 0.7, 0.4)
			e.position = Vector3(sx, 0.42, 2.15)
			car.add_child(e)
			car._exhaust_smoke.append(e)
	# engine damage smoke (dark, from the hood) — shown while health is low
	var mono := car.vehicle_type == "monster"
	car._damage_smoke = _make_smoke(Color(0.09, 0.09, 0.1, 0.85), 0.35, 1.1, 1.0, 2.6, Vector3(0, 1, 0.2), 22, 0.95, 1.4)
	car._damage_smoke.position = Vector3(0, (1.6 if mono else 1.0), (-1.6 if mono else -1.0))
	car.add_child(car._damage_smoke)
	# backfire flame pops at the exhaust
	var bx: Array = [-1.16, 1.16] if mono else [-0.45, 0.45]
	for sx in bx:
		var bf := _make_backfire()
		if mono:
			(bf.process_material as ParticleProcessMaterial).direction = Vector3(0, 1, 0.2)
		bf.position = Vector3(sx, (2.8 if mono else 0.42), (0.3 if mono else 2.2))
		car.add_child(bf)
		car._backfire.append(bf)
func _build_wind() -> void:
	car._wind_streaks = GPUParticles3D.new()
	car._wind_streaks.amount = 26
	car._wind_streaks.lifetime = 0.3
	car._wind_streaks.emitting = false
	car._wind_streaks.local_coords = false
	car._wind_streaks.position = Vector3(0, 0.6, 0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(1.5, 0.8, 2.2)
	pm.direction = Vector3(0, 0, 1)   # local rearward (car faces -Z)
	pm.spread = 5.0
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 24.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.18
	pm.scale_max = 0.32
	pm.particle_flag_align_y = true   # stretch streaks along their travel direction
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.28))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	car._wind_streaks.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.05, 1.3)   # thin, long streak
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1, 1, 1)
	qm.material = m
	car._wind_streaks.draw_pass_1 = qm
	car.add_child(car._wind_streaks)
func _make_backfire() -> GPUParticles3D:
	var g := GPUParticles3D.new()
	g.amount = 12
	g.lifetime = 0.22
	g.one_shot = true
	g.explosiveness = 0.95
	g.emitting = false
	g.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0.35, 1)   # out the back
	pm.spread = 28.0
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 9.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.3
	pm.scale_max = 0.75
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.92, 0.55, 1.0))
	grad.set_color(1, Color(1.0, 0.3, 0.05, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	g.process_material = pm
	var qm := QuadMesh.new(); qm.size = Vector2(0.5, 0.5)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1, 1, 1)
	qm.material = m
	g.draw_pass_1 = qm
	return g
func update_flames(on: bool, delta: float) -> void:
	for f in car._rocket_flames:
		f.emitting = on
	for c in car._rocket_cores:
		c.emitting = on
	if car._boost_light == null:
		return
	if on:
		car._boost_flicker_t += delta * 26.0
		var flick: float = 0.75 + 0.25 * sin(car._boost_flicker_t) + randf_range(-0.12, 0.12)
		car._boost_light.light_energy = 3.2 * clampf(flick, 0.35, 1.25)
	else:
		car._boost_light.light_energy = 0.0
