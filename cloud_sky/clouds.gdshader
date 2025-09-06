shader_type sky;
render_mode use_debanding;

uniform sampler2D blend_from_texture : filter_linear, repeat_disable, source_color;
uniform sampler2D blend_to_texture : filter_linear, repeat_disable, source_color;

uniform sampler2D sky_blend_from_texture : filter_linear, repeat_disable, source_color;
uniform sampler2D sky_blend_to_texture : filter_linear, repeat_disable, source_color;

uniform sampler2D source_transmittance : filter_linear, hint_default_black, repeat_disable;

uniform float blend_amount : hint_range(0.0, 1.0, 0.01);
uniform float sun_disk_scale = 1.0;

uniform float moon_radius : hint_range(0, 1) = 0.05;
uniform float moon_exposure : hint_range(-16, 16) = 0;
uniform samplerCube moon_cubemap : source_color;
uniform mat3 moon_world_to_object;

uniform samplerCube star_cubemap : source_color;
uniform float star_exposure : hint_range(-16, 16) = 0;
uniform float star_power : hint_range(1, 5) = 1;
uniform float star_latitude : hint_range(-90, 90) = 0;
uniform float star_speed = 0.001;
uniform samplerCube star_constellation_cubemap : source_color;
uniform vec3 star_constellation_color : source_color = vec3(0.0, 0.3, 0.6);


const float GROUND_RADIUS_MM = 6.360;
const float ATMOSPHERE_RADIUS_MM = 6.460;
const vec3 VIEW_POS = vec3(0.0, GROUND_RADIUS_MM + 0.0002, 0.0);
const vec2 TLUT_RES = vec2(256.0, 64.0);


vec2 oct_wrap(vec2 v) {
	vec2 sign_val;
	sign_val.x = v.x >= 0.0 ? 1.0 : -1.0;
	sign_val.y = v.y >= 0.0 ? 1.0 : -1.0;
	return (1.0 - abs(v.yx)) * sign_val;
}

vec2 vec3_to_oct(vec3 e) {
	e /= abs(e.x) + abs(e.y) + abs(e.z);
	e.xy = e.z >= 0.0 ? e.xy : oct_wrap( e.xy );

	vec2 n;
	n.y = e.y * 0.5 + 0.5;
	n.x = e.x * 0.5 + n.y;
	n.y = e.x * -0.5 + n.y;

	return n;
}

vec3 get_val_from_sky_lut(vec3 rayDir) {
	vec2 uv;
	float phi = atan(rayDir.z, rayDir.x);
    float theta = asin(rayDir.y);
	uv.x = (phi / PI * 0.5 + 0.5);
    // Undo the non-linear transformation from the sky-view LUT
    uv.y = sqrt(abs(theta) / (PI * 0.5)) * sign(theta) * 0.5 + 0.5;

	vec3 blend_from = texture(sky_blend_from_texture, uv).rgb;
	vec3 blend_to = texture(sky_blend_to_texture, uv).rgb;
    return mix(blend_from, blend_to, blend_amount) / 50.0;// + 0.01; // TODO review, adds a bit of contrast to the night sky
}

// https://www.shadertoy.com/view/slSXRW
/** Returns the sun color plus bloom with a mask for the sun itself in the alpha channel. */
vec4 sun_with_bloom(vec3 ray_dir, vec3 sun_dir) {
    float sun_solid_angle = sun_disk_scale * 0.53*PI/180.0;
    float min_sun_cos_theta = cos(sun_solid_angle);

    float cos_theta = dot(ray_dir, sun_dir);
    if (cos_theta >= min_sun_cos_theta) return vec4(1.0);

    float offset = min_sun_cos_theta - cos_theta;
    float gaussian_bloom = exp(-offset * 500.0) * 0.5; // TODO these constants should be defined or even configurable
    float inv_bloom = 1.0 / (0.02 + offset * 300.0) * 0.01;
	vec3 col = vec3(gaussian_bloom + inv_bloom);
    return vec4(col, (cos_theta >= min_sun_cos_theta) ? 1.0 : 0.0);
}

// TODO see way below, this function is not used right now
vec3 moon_with_bloom(vec3 ray_dir, vec3 sun_dir) {
    float moon_solid_angle = moon_radius;
    float min_sun_cos_theta = cos(moon_solid_angle);

    float cos_theta = dot(ray_dir, sun_dir);
    if (cos_theta >= min_sun_cos_theta) return vec3(0.0); // note that the moon itself is "black" FOR 0.0 like this and we use this to just add bloom

    float offset = min_sun_cos_theta - cos_theta;
    float gaussian_bloom = exp(-offset * 5000.0) * 0.5;
    float inv_bloom = 1.0 / (0.02 + offset * 30.0) * 0.01;
    return vec3(gaussian_bloom + inv_bloom);
}

float ray_intersect_sphere(vec3 ro, vec3 rd, float rad) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - rad*rad;
    if (c > 0.0f && b > 0.0) return -1.0;
    float discr = b*b - c;
    if (discr < 0.0) return -1.0;
    // Special case: inside sphere, use far discriminant
    if (discr > b * b) return (-b + sqrt(discr));
    return -b - sqrt(discr);
}

vec3 get_val_from_tlut(sampler2D tex, vec2 buffer_res, vec3 pos, vec3 sun_dir) {
    float height = length(pos);
    vec3 up = pos / height;
	float sun_cos_zenith_angle = dot(up, sun_dir);
    vec2 uv = vec2(TLUT_RES.x * clamp(0.5 + 0.5 * sun_cos_zenith_angle, 0.0, 1.0),
                  TLUT_RES.y * max(0.0, min(1.0, (height - GROUND_RADIUS_MM) / (ATMOSPHERE_RADIUS_MM - GROUND_RADIUS_MM))));
    uv /= buffer_res;
    return texture(tex, uv).rgb;
}

vec4 get_lum_sun(vec3 dir, vec3 light_dir) {
	vec4 lum = sun_with_bloom(dir, light_dir);
    // Use smoothstep to limit the effect, so it drops off to actual zero.
    lum.rgb = smoothstep(0.002, 1.0, lum.rgb);
    if (length(lum.rgb) > 0.0) {
        if (ray_intersect_sphere(VIEW_POS, dir, GROUND_RADIUS_MM) >= 0.0) {
            lum.rgb *= 0.0;
			lum.a = 0.0;

        } else {
            // If the light value is applied to this pixel, we need to calculate the
			// transmittance to obscure it.
        	lum.rgb *= get_val_from_tlut(source_transmittance, TLUT_RES, VIEW_POS, light_dir);
		}
    }
	return lum;
}

vec3 get_moon_texture(vec3 moon_dir, vec3 dir) {
	dir = moon_world_to_object * dir;
	// Rotate 180 degrees by flipping both x and z.
	dir.x = -dir.x;
	dir.z = -dir.z;

	return texture(moon_cubemap, dir).rgb;
}

vec4 get_lum_moon(vec3 dir, vec3 sun_dir, vec3 moon_dir) {
	// TODO I'm still struggling a bit getting the bloom to properly apply and only on the
	// part of the moon that's actually lit, so although we execute the first half of this
	// function, we actually do not use the result "lum" in the second part, yet.
	vec3 lum = moon_with_bloom(dir, moon_dir);
    // Use smoothstep to limit the effect, so it drops off to actual zero.
    lum = smoothstep(0.002, 1.0, lum);
    if (length(lum) > 0.0) {
        if (ray_intersect_sphere(VIEW_POS, dir, GROUND_RADIUS_MM) >= 0.0) {
            lum *= 0.0;
        } else {
            // If the light value is applied to this pixel, we need to calculate the
			// transmittance to obscure it.
        	lum *= get_val_from_tlut(source_transmittance, TLUT_RES, VIEW_POS, moon_dir);
		}
    }
	// Moon has a texture that is lit by the sun.
	float moon_intersect = ray_intersect_sphere(moon_dir, -dir, moon_radius);
	float moon_mask = moon_intersect > -1.0 ? 1.0 : 0.0;
	vec3 moon_normal = normalize(dir * moon_intersect - moon_dir);
	float moon_ndotl = clamp(dot(moon_normal, sun_dir), 0.0, 1.0);
	vec3 moon_texture = get_moon_texture(moon_dir, moon_normal);
	vec3 moon_output = moon_mask * moon_ndotl * exp2(moon_exposure) * moon_texture;
	//return vec4(moon_output+lum, moon_mask); // TODO see above :)
	return vec4(moon_output, moon_mask);
}

// Construct a rotation matrix that rotates around a particular axis by angle
// Adapted from: https://github.com/dmnsgn/glsl-rotate
mat3 rotation_3d(vec3 axis, float angle) {
  axis = normalize(axis);
  float s = sin(angle);
  float c = cos(angle);
  float oc = 1.0 - c;

  return mat3(
    vec3(oc * axis.x * axis.x + c,           oc * axis.x * axis.y - axis.z * s,  oc * axis.z * axis.x + axis.y * s),
    vec3(oc * axis.x * axis.y + axis.z * s,  oc * axis.y * axis.y + c,           oc * axis.y * axis.z - axis.x * s),
    vec3(oc * axis.z * axis.x - axis.y * s,  oc * axis.y * axis.z + axis.x * s,  oc * axis.z * axis.z + c));
}

// Rotate the view direction, tilt with latitude, spin with time
vec3 get_star_uvw(vec3 view_dir, float latitude, float local_sidereal_time) {
    // tilt = 0 at the north pole, where latitude = 90 degrees
    float tilt = PI * (latitude - 90.0) / 180.0;
    mat3 tilt_rotation = rotation_3d(vec3(-1.0, 0.0, 0.0), tilt);

    // 0.75 is a texture offset for lST = 0 equals noon
    float spin = (0.75 - local_sidereal_time) * 2.0 * PI;
    mat3 spin_rotation = rotation_3d(vec3(0.0, 1.0, 0.0), spin);

    // The order of rotation is important
    return spin_rotation * tilt_rotation * view_dir;
}

/** Returns the color for the stars in the night sky.  */
vec3 get_stars(vec3 view_dir, vec3 sun_dir, vec3 moon_dir, vec4 sun, vec4 moon) {
	// Main angles
	float sun_view_dot = dot(sun_dir, view_dir);
	float sun_zenith_dot = sun_dir.y;
	float sun_view_dot01 = (sun_view_dot + 1.0) * 0.5;

	// The stars
	vec3 star_uvw = get_star_uvw(view_dir, star_latitude, mod(TIME *  star_speed, 1.0));
	vec3 star_output = texture(star_cubemap, star_uvw).rgb;
	star_output = pow(star_output, vec3(star_power));
	float star_strength = (1.0 - sun_view_dot01) * (clamp(-sun_zenith_dot, 0.0, 1.0));
	float star_mask = 1.0 * (1.0 - moon.a) * (1.0 - sun.a);
	star_output *= star_mask * exp2(star_exposure) * (star_strength);

	// The constellations
	vec3 constellation_output = texture(star_constellation_cubemap, star_uvw).rgb;
	constellation_output *= star_constellation_color * (star_mask) * star_strength;

	return star_output + constellation_output;
}

/** Renders the effects of a solar and/or lunar eclipse by modifying the sun, moon and sky output. */
void render_solar_and_lunar_eclipse(vec3 view_dir, vec3 sun_dir, vec3 moon_dir, inout vec4 sun, inout vec4 moon, inout vec3 sky_output) {
	float sun_view_dot = dot(sun_dir, view_dir);
	float sun_moon_dot = dot(sun_dir, moon_dir);

	// Solar eclipse
	float sun_radius = sun_disk_scale * 2.0*PI/180.0;// 0.2; // TODO this should be something else
	float solar_eclipse01 = smoothstep(1.0 - sun_radius * sun_radius, 1.0, sun_moon_dot);
	sky_output *= mix(1.0, 0.4, solar_eclipse01);
	sun.rgb *= (1.0 - moon.a) * mix(1.0, 3.0, solar_eclipse01);

	// Lunar eclipse
	float lunar_eclipse_mask = 1.0 - step(1.0 - sun_radius * sun_radius, -sun_view_dot);
	float lunar_eclipse01 = smoothstep(1.0 - sun_radius * sun_radius * 0.05, 1.0, -sun_moon_dot);
	moon.rgb *= mix(vec3(lunar_eclipse_mask), vec3(0.3,0.05,0), lunar_eclipse01);
}

vec3 get_atmo(vec3 dir) {
	vec3 sky_col = get_val_from_sky_lut(dir);
	vec4 sun_col = get_lum_sun(dir, LIGHT0_DIRECTION);
	vec4 moon_col = get_lum_moon(dir, LIGHT0_DIRECTION, LIGHT1_DIRECTION);
	vec3 stars_col = get_stars(dir, LIGHT0_DIRECTION, LIGHT1_DIRECTION, sun_col, moon_col);
	render_solar_and_lunar_eclipse(dir, LIGHT0_DIRECTION, LIGHT1_DIRECTION, sun_col, moon_col, sky_col);
	sky_col += sun_col.rgb;
	sky_col += moon_col.rgb;
	sky_col += stars_col;
	return sky_col.rgb;
}

void sky() {
	vec3 norm = EYEDIR;
	norm.y = max(0.0, norm.y);
	norm = normalize(norm);
	norm.xz = vec3_to_oct(norm.xzy);
	vec4 blend_from = textureLod(blend_from_texture, norm.xz, 0.0);
	vec4 blend_to = textureLod(blend_to_texture, norm.xz, 0.0);
	vec4 clouds = mix(blend_from, blend_to, blend_amount);
	vec3 background = get_atmo(EYEDIR);
	COLOR = background * (1.0 - clouds.a) + clouds.xyz;
	COLOR = mix(clamp(COLOR, vec3(0.0), vec3(100.0)), clamp(background, vec3(0.0), vec3(100.0)), smoothstep(0.6, 1.0, 1.0 - EYEDIR.y));
}
