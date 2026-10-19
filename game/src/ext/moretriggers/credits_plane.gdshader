shader_type canvas_item;
// MoreTriggers credits: the text plane (a picture of it in TEXTURE) tilted around the X axis by `angle` and seen
// in perspective like Flash's rotationX + PerspectiveProjection. Drawn as one rectangle over the whole window; each
// pixel is traced back to the point of the plane it shows.

uniform vec2 stage = vec2(700.0, 600.0);
uniform vec2 center = vec2(400.0, 300.0);   // projection centre
uniform float focal = 600.0;                // focal length (from the field of view)
uniform float angle = 0.0;                  // rotationX, radians
uniform vec2 plane_origin = vec2(0.0);      // plane point at the picture's top left
uniform vec2 plane_size = vec2(700.0, 600.0);

varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec2 s = UV * stage;
	float c = cos(angle);
	float sn = sin(angle);
	float den = c * focal - (s.y - center.y) * sn;
	vec4 col = vec4(0.0);
	if (abs(den) > 1e-4) {
		float y = s.y * focal / den;
		float w = focal + y * sn;
		if (w > 0.0) {
			float x = center.x + (s.x - center.x) * w / focal;
			vec2 uv = (vec2(x, y) - plane_origin) / plane_size;
			if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
				col = texture(TEXTURE, uv);
			}
		}
	}
	COLOR = col * tint;
}
