shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Photo-textured ground for the realistic maps: one shader for the road ribbon
// (asphalt + painted markings + sand blown in at the edges, then open desert past the
// barrier) and for the surrounding land (sand floor, banded sandstone on anything steep).
// Both sample the desert layers by WORLD position, so the ribbon's verge and the land
// under it are the same surface and the join between the two meshes cannot be seen.
//
// Ribbon vertex data (HCTrack._build_tile): UV = (lateral metres, arc-length metres),
// UV2 = (drivable half-width, turn-widen 0..1), COLOR = painted override (a = amount).

uniform float is_road = 0.0;

uniform sampler2D asphalt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asphalt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asphalt_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cliff_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cliff_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cliff_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 asphalt_tint : source_color = vec3(1.0);
uniform vec3 sand_tint : source_color = vec3(1.0);
uniform vec3 cliff_tint : source_color = vec3(1.0);
uniform vec3 line_color : source_color = vec3(0.86, 0.85, 0.80);
uniform vec3 kerb_color : source_color = vec3(0.62, 0.07, 0.05);
uniform vec3 centre_color : source_color = vec3(0.80, 0.57, 0.10);
uniform float normal_strength = 1.0;

// far land only: the square the fine near-land covers; the coarse mesh is cut out there
uniform vec4 cut_rect = vec4(0.0);   // (centre x, centre z, half size, enabled)

varying vec3 world_pos;
varying vec3 world_nrm;
varying vec3 world_tan;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	world_tan = (MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz;
}

vec3 unpack_n(vec4 t) {
	vec3 n = t.xyz * 2.0 - 1.0;
	n.xy *= normal_strength;
	return n;
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void fragment() {
	if (cut_rect.w > 0.5) {
		vec2 dc = abs(world_pos.xz - cut_rect.xy);
		if (max(dc.x, dc.y) < cut_rect.z) {
			discard;
		}
	}
	vec3 wn = normalize(world_nrm);
	float vdist = length(VERTEX);
	float far_w = smoothstep(35.0, 220.0, vdist);

	// --- shared large-scale variation --------------------------------------------
	float n_macro = texture(noise_tex, world_pos.xz * 0.0031).r;
	float n_mid = texture(noise_tex, world_pos.xz * 0.019 + vec2(0.37, 0.11)).r;
	float n_fine = texture(noise_tex, world_pos.xz * 0.11 + vec2(0.71, 0.53)).r;

	// --- desert floor: sand with patches of stonier red dirt ---------------------
	// two tile sizes cross-faded by distance: the photo's own scale up close, a much
	// larger repeat far away where the small one would read as a visible grid
	vec2 uv_g = vec2(world_pos.x, -world_pos.z);
	vec3 s_near = texture(sand_albedo, uv_g * 0.19).rgb;
	vec3 s_far = texture(sand_albedo, uv_g * 0.023 + vec2(0.4, 0.2)).rgb;
	vec3 sand_c = mix(s_near, s_far, far_w * 0.85);
	vec3 sand_n = unpack_n(texture(sand_normal, uv_g * 0.19));
	sand_n = mix(sand_n, unpack_n(texture(sand_normal, uv_g * 0.023 + vec2(0.4, 0.2))), far_w * 0.85);
	vec3 sand_m = texture(sand_orm, uv_g * 0.19).rgb;
	float dirt_w = smoothstep(0.48, 0.66, n_mid * 0.65 + n_macro * 0.35);
	if (dirt_w > 0.001) {
		vec3 d_c = mix(texture(dirt_albedo, uv_g * 0.27).rgb, texture(dirt_albedo, uv_g * 0.031).rgb, far_w * 0.85);
		// the laterite photo is much darker than the sand; lift it so a patch reads as
		// redder, stonier ground rather than a wet stain
		sand_c = mix(sand_c, d_c * 1.55, dirt_w * 0.75);
		sand_n = mix(sand_n, unpack_n(texture(dirt_normal, uv_g * 0.27)), dirt_w * 0.75 * (1.0 - far_w));
	}
	sand_c *= sand_tint * mix(0.86, 1.10, n_macro);

	vec3 albedo = sand_c;
	float rough = clamp(sand_m.g + 0.05, 0.0, 1.0);
	float ao = sand_m.r;
	float spec = 0.35;
	// tangent normal on the ground plane: U = +X, image-up = +Z
	vec3 w_normal = normalize(vec3(wn.x + sand_n.x, wn.y, wn.z + sand_n.y));

	// --- steep ground: banded sandstone, projected from the sides ----------------
	float slope = 1.0 - wn.y;
	float cliff_w = smoothstep(0.14, 0.34, slope + (n_fine - 0.5) * 0.08);
	if (cliff_w > 0.001) {
		vec3 bl = abs(wn);
		bl = pow(bl, vec3(6.0));
		bl /= (bl.x + bl.y + bl.z);
		float ck = 0.052;
		vec2 uvx = vec2(world_pos.z, -world_pos.y) * ck;
		vec2 uvz = vec2(world_pos.x, -world_pos.y) * ck;
		vec2 uvy = uv_g * ck;
		vec3 c_c = texture(cliff_albedo, uvx).rgb * bl.x + texture(cliff_albedo, uvz).rgb * bl.z + texture(cliff_albedo, uvy).rgb * bl.y;
		vec3 c_m = texture(cliff_orm, uvx).rgb * bl.x + texture(cliff_orm, uvz).rgb * bl.z + texture(cliff_orm, uvy).rgb * bl.y;
		vec3 tx = unpack_n(texture(cliff_normal, uvx));
		vec3 tz = unpack_n(texture(cliff_normal, uvz));
		vec3 ty = unpack_n(texture(cliff_normal, uvy));
		tx = vec3(tx.xy + wn.zy, abs(tx.z) * wn.x);
		tz = vec3(tz.xy + wn.xy, abs(tz.z) * wn.z);
		ty = vec3(ty.xy + wn.xz, abs(ty.z) * wn.y);
		vec3 c_n = normalize(tx.zyx * bl.x + tz.xyz * bl.z + ty.xzy * bl.y);
		// strata: sediment layers are level, so the banding is a function of height
		// alone, bent a little by slow noise so the lines are not ruler-straight
		float sy = world_pos.y + (n_mid - 0.5) * 2.5 + (n_macro - 0.5) * 7.0;
		float band_a = textureLod(noise_tex, vec2(sy * 0.0052, 0.23), 2.0).r;
		float band_b = textureLod(noise_tex, vec2(sy * 0.019, 0.61), 1.0).r;
		vec3 strata = mix(vec3(0.80, 0.56, 0.45), vec3(1.16, 1.00, 0.84), smoothstep(0.3, 0.7, band_a));
		strata *= mix(0.90, 1.07, band_b);
		c_c *= strata * cliff_tint;
		albedo = mix(albedo, c_c, cliff_w);
		rough = mix(rough, c_m.g, cliff_w);
		ao = mix(ao, c_m.r, cliff_w);
		w_normal = normalize(mix(w_normal, c_n, cliff_w));
	}

	// --- road ribbon: asphalt and paint -------------------------------------------
	if (is_road > 0.5) {
		float lat = UV.x;
		float s = UV.y;
		float rh = UV2.x;
		float widen = UV2.y;
		float al = abs(lat);
		float ragged = (texture(noise_tex, vec2(s * 0.021, lat * 0.03)).r - 0.5) * 0.5;
		float road = 1.0 - smoothstep(rh - 0.10, rh + 0.30, al + ragged);
		if (road > 0.001) {
			vec2 uv_a = vec2(lat, s);
			vec3 a_c = texture(asphalt_albedo, uv_a * 0.31).rgb;
			vec3 a_far = texture(asphalt_albedo, uv_a * 0.043 + vec2(0.3, 0.7)).rgb;
			a_c = mix(a_c, a_far, 0.25 + far_w * 0.6);
			vec3 a_n = unpack_n(texture(asphalt_normal, uv_a * 0.31));
			vec3 a_m = texture(asphalt_orm, uv_a * 0.31).rgb;
			float a_rough = a_m.g;

			// laid in strips by the paving machine: each strip weathers its own shade,
			// with a sealed joint between neighbours
			float lane = (lat + 400.0) / 5.6;
			float lane_id = floor(lane);
			float shade = hash11(lane_id * 7.13 + floor(s / 230.0 + hash11(lane_id) * 3.0) * 1.7);
			a_c *= mix(0.84, 1.10, shade);
			float jd = abs(fract(lane + 0.5) - 0.5) * 5.6;
			float joint = (1.0 - smoothstep(0.03, 0.09, jd)) * (1.0 - smoothstep(60.0, 150.0, vdist));
			a_c = mix(a_c, a_c * 0.55, joint * 0.7);

			// repairs: the odd rectangular patch of newer, darker tarmac
			vec2 pg = vec2(lat / 3.8, s / 17.0);
			vec2 pid = floor(pg);
			float ph = hash11(pid.x * 13.7 + pid.y * 71.3);
			if (ph > 0.94) {
				vec2 pf = fract(pg);
				float inset = step(0.08, pf.x) * step(pf.x, 0.92) * step(0.05, pf.y) * step(pf.y, 0.75 + ph * 0.2 - 0.19);
				a_c = mix(a_c, a_c * 0.62, inset * 0.8);
				a_rough = mix(a_rough, a_rough * 0.92, inset);
			}
			// thermal cracks run ACROSS a road, a strip at a time, and get sealed with a
			// bead of tar: a dark, slightly wandering line every so often per paving strip
			float seg = 31.0 + 17.0 * hash11(lane_id * 3.3);
			float sw = s + (texture(noise_tex, vec2(lat * 0.09, s * 0.011)).r - 0.5) * 2.4 + hash11(lane_id) * seg;
			float sc = abs(fract(sw / seg) - 0.5) * seg;
			float present = step(0.35, hash11(floor(sw / seg) * 5.1 + lane_id * 1.9));
			float tar = (1.0 - smoothstep(0.035, 0.075, sc)) * present * (1.0 - smoothstep(55.0, 140.0, vdist));
			a_c = mix(a_c, a_c * 0.38, tar * 0.85);
			// weather: big slow blotches, plus the darker, polished line the cars run
			a_c *= mix(0.80, 1.14, n_mid) * mix(0.90, 1.06, n_macro);
			// scuffs: long faint streaks of rubber laid down along the direction of travel
			float streak = texture(noise_tex, vec2(lat * 0.23, s * 0.0041)).r;
			a_c *= 1.0 - smoothstep(0.56, 0.74, streak) * 0.22;
			float line_c = sin(s * 0.013) * rh * 0.22;
			float groove = exp(-pow((lat - line_c) / 4.2, 2.0));
			float tyre = 0.55 + 0.45 * texture(noise_tex, vec2(lat * 0.35, s * 0.004)).r;
			a_c *= 1.0 - groove * 0.30 * tyre;
			a_rough -= groove * 0.10;
			a_c *= asphalt_tint;

			// sand creeping in from the verge
			float drift = smoothstep(rh - 5.5, rh + 0.3, al + (n_fine - 0.5) * 3.2 + (n_mid - 0.5) * 3.0);
			drift *= 0.82;

			// paint: a solid white edge line; red/white kerb blocks through the bends
			float wear = smoothstep(0.18, 0.5, texture(noise_tex, vec2(lat * 0.9, s * 0.07)).r + n_fine * 0.25);
			float px = fwidth(lat) * 1.2;
			float e_line = 1.0 - smoothstep(0.10 - px * 0.5, 0.10 + px, abs(al - (rh - 2.6)));
			float kerb_zone = (1.0 - smoothstep(0.55 - px * 0.5, 0.55 + px, abs(al - (rh - 1.75))));
			kerb_zone *= smoothstep(0.28, 0.5, widen);
			float block = step(0.5, fract(s / 5.0));
			vec3 kerb_c = mix(vec3(0.84, 0.83, 0.80), kerb_color, block);
			vec3 paint_c = line_color;
			float paint = e_line * mix(0.55, 0.95, wear);
			paint_c = mix(paint_c, kerb_c, kerb_zone);
			paint = max(paint, kerb_zone * mix(0.7, 0.97, wear));
			// centre line, highway yellow: dashed on the straights, solid through the
			// bends (the same widen signal that lays the kerbs), so the line itself says
			// a corner is coming. Never thinner than about a pixel: far down the road it
			// is the one mark that shows which way the tarmac goes.
			float c_half = max(0.17, px * 0.75);
			float c_line = 1.0 - smoothstep(c_half - px * 0.5, c_half + px, al);
			float ds = fwidth(s) / 12.0;
			float dph = fract(s / 12.0);
			float dash = smoothstep(0.0, ds, dph) * (1.0 - smoothstep(0.58, 0.58 + ds, dph));
			dash = mix(dash, 0.58, smoothstep(0.2, 0.5, ds));
			c_line *= max(dash, smoothstep(0.28, 0.5, widen));
			paint_c = mix(paint_c, centre_color, c_line);
			paint = max(paint, c_line * mix(0.72, 0.97, wear));
			// distant paint thinner than a pixel shimmers; let it fade into the asphalt
			paint *= 1.0 - smoothstep(180.0, 420.0, vdist) * 0.6;
			a_c = mix(a_c, paint_c, paint);
			a_rough = mix(a_rough, 0.62, paint);

			// level-design paint (jump ramps, landing pads) baked into vertex colour
			a_c = mix(a_c, COLOR.rgb * mix(0.8, 1.0, a_m.g), COLOR.a);

			// the ribbon runs any which way, so bend the surface normal in the road's own
			// frame: the mesh tangent is the row's "right" vector (U = lateral), and the
			// photo's up is back down the road (V = arc-length, image rows run downward)
			vec3 t_lat = normalize(world_tan - wn * dot(wn, world_tan));
			vec3 t_s = cross(wn, t_lat);
			vec3 road_n = normalize(wn + (t_lat * a_n.x - t_s * a_n.y) * 0.6 * (1.0 - paint * 0.6) * (1.0 - far_w * 0.7));

			float keep = road * (1.0 - drift);
			albedo = mix(albedo, a_c, keep);
			rough = mix(rough, clamp(a_rough, 0.55, 1.0), keep);
			ao = mix(ao, a_m.r, keep);
			spec = mix(spec, 0.32, keep);
			w_normal = normalize(mix(w_normal, road_n, keep));
		}
	}

	ALBEDO = albedo;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = spec;
	AO = ao;
	AO_LIGHT_AFFECT = 0.35;
	NORMAL = normalize((VIEW_MATRIX * vec4(w_normal, 0.0)).xyz);
}
