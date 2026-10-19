#include "sweat.h"

#include "sdt_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

// The logic follows Sweat.gd (the port of obj.Sweat, which remains the fallback). Differences: hit tests leave all
// droplets out (the original left out only the testing droplet), a droplet at rest has no direction (the
// original's 0 / 0 could freeze the game), and the first attached tick's stretch, which the original computed from
// an undefined previous speed, is 1.

namespace {

constexpr float NEAR_DIST = 4.0f;
constexpr float FREE_GRAVITY = 3.0f;
constexpr float ATTACHED_GRAVITY = 0.15f;
constexpr float FRICTION = 0.9f;
constexpr float DEG = 3.14159265358979f / 180.0f;

float randf() {
	return (float)UtilityFunctions::randf();
}

} // namespace

void SDTSweat::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_container", "obj"), &SDTSweat::add_container);
	ClassDB::bind_method(D_METHOD("set_children", "container", "children", "parent_key", "index"), &SDTSweat::set_children);
	ClassDB::bind_method(D_METHOD("set_transforms", "transforms", "rotations", "own"), &SDTSweat::set_transforms);
	ClassDB::bind_method(D_METHOD("spawn", "parent", "p", "spread", "others", "max_drops"), &SDTSweat::spawn);
	ClassDB::bind_method(D_METHOD("tick", "tick"), &SDTSweat::tick);
	ClassDB::bind_method(D_METHOD("get_draw", "container"), &SDTSweat::get_draw);
	ClassDB::bind_method(D_METHOD("parents_in_use"), &SDTSweat::parents_in_use);
	ClassDB::bind_method(D_METHOD("clear"), &SDTSweat::clear);
	ClassDB::bind_method(D_METHOD("count"), &SDTSweat::count);
}

int SDTSweat::add_container(Object *obj) {
	Container c;
	c.obj = obj ? ObjectID(obj->get_instance_id()) : ObjectID();
	containers.push_back(c);
	return (int)containers.size() - 1;
}

void SDTSweat::set_children(int c, const PackedInt32Array &children, int64_t parent_key, int index) {
	if (c < 0 || c >= (int)containers.size()) {
		return;
	}
	containers[c].children.assign(children.ptr(), children.ptr() + children.size());
	containers[c].parent_key = parent_key;
	containers[c].index = index;
}

void SDTSweat::set_transforms(const Array &transforms, const PackedFloat32Array &rotations, const PackedFloat32Array &own) {
	int n = std::min((int)transforms.size(), (int)containers.size());
	for (int i = 0; i < n; i++) {
		Transform2D t = transforms[i];
		containers[i].to_stage = t;
		containers[i].from_stage = t.affine_inverse();
		if (i < rotations.size()) {
			containers[i].rot = rotations[i];
		}
		if (i < own.size()) {
			containers[i].own_rot = own[i];
		}
	}
}

bool SDTSweat::hit(int c, Vector2 gp) const {
	if (c < 0 || c >= (int)containers.size()) {
		return false;
	}
	Object *o = ObjectDB::get_instance(containers[c].obj);
	return o != nullptr && sdt_hit_flat(o, containers[c].from_stage.xform(gp), tick_key);
}

// hitTestPoint(x, y, false): the stage-space bounding box of the object's shapes
bool SDTSweat::in_bounds(int c, Vector2 gp) const {
	if (c < 0 || c >= (int)containers.size()) {
		return false;
	}
	Object *o = ObjectDB::get_instance(containers[c].obj);
	if (o == nullptr) {
		return false;
	}
	Rect2 r = sdt_flat_bounds(o, tick_key);
	const Transform2D &t = containers[c].to_stage;
	Vector2 a = t.xform(r.position), b = t.xform(r.position + Vector2(r.size.x, 0)),
			cc = t.xform(r.position + Vector2(0, r.size.y)), d = t.xform(r.position + r.size);
	float x0 = std::min(std::min(a.x, b.x), std::min(cc.x, d.x)), x1 = std::max(std::max(a.x, b.x), std::max(cc.x, d.x));
	float y0 = std::min(std::min(a.y, b.y), std::min(cc.y, d.y)), y1 = std::max(std::max(a.y, b.y), std::max(cc.y, d.y));
	return gp.x >= x0 && gp.x <= x1 && gp.y >= y0 && gp.y <= y1;
}

// c: a container, -1: the droplet's parent, -2: the stage
Vector2 SDTSweat::to_global(const Drop &d, int c, Vector2 p) const {
	if (c == -1) {
		c = d.parent;
	}
	if (c < 0 || c >= (int)containers.size()) {
		return p;
	}
	return containers[c].to_stage.xform(p);
}

Vector2 SDTSweat::from_global(int c, Vector2 gp) const {
	if (c < 0 || c >= (int)containers.size()) {
		return gp;
	}
	return containers[c].from_stage.xform(gp);
}

// gVec: "down" in the space the droplet slides on, from the summed rotations (parentDown)
Vector2 SDTSweat::down_of(const Drop &d, int c) const {
	if (c == -1) {
		c = d.parent;
	}
	float ang = 180.0f;
	if (c >= 0 && c < (int)containers.size()) {
		ang = 180.0f - containers[c].rot;
	}
	return Vector2(std::sin(ang * DEG), -std::cos(ang * DEG));
}

void SDTSweat::add_to_parent(int id, int c) {
	Drop &d = drops[id];
	d.parent = c;
	d.children = containers[c].children;
	d.on_child = -1;
	jump_to_child(id);
	containers[c].drops.push_back(id);
}

void SDTSweat::jump_to_child(int id) {
	Drop &d = drops[id];
	d.global = to_global(d, -1, d.pos);
	Vector2 ahead = to_global(d, d.on_child, d.local + d.speed);
	for (int c : d.children) {
		if (in_bounds(c, d.global) && hit(c, d.global)) {
			d.on_child = c;
			Vector2 a = from_global(c, ahead);
			d.local = from_global(c, d.global);
			d.speed = a - d.local;
			d.not_on_parent = true;
			return;
		}
	}
	d.on_child = -1;
	d.not_on_parent = false;
	d.local = d.pos;
	Vector2 a = from_global(d.parent, ahead);
	d.speed = a - d.local;
}

void SDTSweat::kill(int id) {
	Drop &d = drops[id];
	if (!d.alive) {
		return;
	}
	d.alive = false;
	if (d.parent >= 0 && d.parent < (int)containers.size()) {
		std::vector<int> &v = containers[d.parent].drops;
		v.erase(std::remove(v.begin(), v.end(), id), v.end());
	}
	count_ -= 1;
}

void SDTSweat::step(int id) {
	Drop &d = drops[id];
	// merging with droplets nearby on the same part (the bigger one absorbs the smaller)
	{
		float r = NEAR_DIST * std::max(d.mass, d.max_mass);
		std::vector<int> near;
		for (int o : containers[d.parent].drops) {
			if (o == id) {
				continue;
			}
			Vector2 q = drops[o].pos;
			if (q.x >= d.pos.x - r && q.x <= d.pos.x + r && q.y >= d.pos.y - r && q.y <= d.pos.y + r) {
				near.push_back(o);
			}
		}
		for (int o : near) {
			Drop &s = drops[o];
			if (!s.alive) {
				continue;
			}
			float nd = NEAR_DIST * d.mass;
			if (s.pos.x >= d.pos.x - nd && s.pos.x <= d.pos.x + nd && s.pos.y >= d.pos.y - nd && s.pos.y <= d.pos.y + nd) {
				if (s.mass > d.mass) {
					s.mass = std::min(s.max_mass, s.mass + d.mass);
					kill(id);
					return;
				}
				d.mass = std::min(d.max_mass, d.mass + s.mass);
				kill(o);
			}
		}
	}
	d.rot = 360.0f - containers[d.parent].rot;
	d.gvec = down_of(d, d.on_child);
	d.local += d.speed;
	d.speed *= FRICTION;
	d.global = to_global(d, d.on_child, d.local);
	d.pos = d.not_on_parent ? from_global(d.parent, d.global) : d.local;
	if (d.global.y > 1000.0f || std::isnan(d.global.x) || std::isnan(d.global.y)) {
		kill(id);
		return;
	}
	d.last_velocity = d.velocity;
	d.velocity = std::sqrt(d.speed.x * d.speed.x + d.speed.y * d.speed.y);
	d.svec = d.velocity > 0.0f ? d.speed / d.velocity : Vector2();
	if (d.attached) {
		float dv = (d.velocity - d.last_velocity) * 0.5f;
		float sy = std::isnan(dv) ? 1.0f : 1.0f + std::max(-0.3f, std::min(0.3f, dv));
		d.sx = 1.0f / sy * d.mass;
		d.sy = sy * d.mass;
		d.alpha = d.mass + 0.5f;
		d.mass = std::min(d.max_mass, d.mass + randf() * 0.01f);
		d.speed += ATTACHED_GRAVITY * d.gvec * std::max(0.0f, d.mass - 0.5f);
		if (hit(d.parent, d.global)) {
			d.left_push *= 0.8f;
			d.right_push *= 0.8f;
			if (d.predict_toggle < 1) {
				d.predict_toggle += 1;
			} else {
				d.predict_toggle = 0;
				Vector2 gp = d.global, s = d.svec;
				float pd = d.predict_dist;
				if (!hit(d.parent, Vector2(gp.x - s.y * pd * 2, gp.y + s.x * pd * 2))) {
					d.right_push = std::min(d.velocity * 0.4f, d.left_push + 0.08f);
				}
				if (!hit(d.parent, Vector2(gp.x + s.y * pd * 2, gp.y - s.x * pd * 2))) {
					d.left_push = std::min(d.velocity * 0.4f, d.right_push + 0.08f);
				}
				if (!hit(d.parent, Vector2(gp.x + s.x * 8 * pd - s.y * pd, gp.y + s.y * 8 * pd + s.x * pd))) {
					d.left_push = std::min(d.velocity * 0.2f, d.left_push + 0.08f);
				}
				if (!hit(d.parent, Vector2(gp.x + s.x * 8 * pd + s.y * pd, gp.y + s.y * 8 * pd - s.x * pd))) {
					d.right_push = std::min(d.velocity * 0.2f, d.right_push + 0.08f);
				}
				if (d.not_on_parent) {
					if (!hit(d.on_child, gp)) {
						jump_to_child(id);
					}
				} else {
					jump_to_child(id);
				}
			}
			d.speed.x += d.left_push * d.svec.y - d.right_push * d.svec.y;
			d.speed.y += d.right_push * d.svec.x - d.left_push * d.svec.x;
		} else {
			// not on the part any more: look for its edge sideways, else let go
			float probe = 1.0f;
			float max_probe = std::min(8.0f, std::abs(d.speed.y * 2.0f));
			if (std::isnan(max_probe)) {
				max_probe = 0.0f;
			}
			while (d.attached) {
				if (std::abs(probe) > max_probe) {
					d.left_push = 0.0f;
					d.right_push = 0.0f;
					d.attached = false;
					d.local = d.global;
					d.on_child = -2;
					d.not_on_parent = true;
					d.just_detached = true;
				} else {
					Vector2 g = d.gvec;
					if (hit(d.parent, Vector2(d.global.x + g.y * probe, d.global.y + g.x * probe))) {
						d.speed.x += g.y * probe * 0.8f;
						d.speed.y += g.x * probe * 0.8f;
						float l = std::sqrt(d.speed.x * d.speed.x + d.speed.y * d.speed.y);
						if (l > 0.0f) {
							d.speed *= d.velocity / l;
						}
						break;
					}
					probe = probe > 0.0f ? -probe : -probe + 1.0f;
				}
			}
		}
	} else {
		d.speed += FREE_GRAVITY * d.gvec;
		if (hit(d.parent, d.global)) {
			d.attached = true;
			d.speed *= 0.4f;
		} else {
			std::vector<int> others = d.others;
			for (int c : others) {
				if (!hit(c, d.global)) {
					continue;
				}
				if (!d.just_detached) {
					// lands on a neighbouring part
					Vector2 ahead = from_global(c, to_global(d, d.on_child, d.local + d.speed));
					d.local = from_global(c, d.global);
					d.speed = ahead - d.local;
					d.pos = d.local;
					d.attached = true;
					d.speed *= 0.4f;
					std::vector<int> &v = containers[d.parent].drops;
					v.erase(std::remove(v.begin(), v.end(), id), v.end());
					add_to_parent(id, c);
					break;
				}
				const Container &p = containers[d.parent], &cc = containers[c];
				if (p.parent_key == cc.parent_key && p.index < cc.index) {
					d.others.erase(std::remove(d.others.begin(), d.others.end(), c), d.others.end());
				}
			}
		}
		d.just_detached = false;
	}
}

bool SDTSweat::spawn(int parent, const Vector2 &p, const Vector2 &spread, const PackedInt32Array &others, int max_drops) {
	if (count_ >= max_drops || parent < 0 || parent >= (int)containers.size()) {
		return false;
	}
	count_ += 1;
	int id;
	if (!free_ids.empty()) {
		id = free_ids.back();
		free_ids.pop_back();
		drops[id] = Drop();
	} else {
		drops.emplace_back();
		id = (int)drops.size() - 1;
	}
	Drop &d = drops[id];
	d.alive = true;
	d.others.assign(others.ptr(), others.ptr() + others.size());
	Vector2 q = p;
	q.x += ((randf() + randf() + randf()) / 3.0f - 0.5f) * spread.x;
	q.y += ((randf() + randf() + randf()) / 3.0f - 0.5f) * spread.y;
	d.pos = q;
	d.local = q;
	d.alpha = 0.0f;
	d.predict_dist = 7.0f + randf() * 6.0f;
	d.max_mass = 0.8f + randf() * 0.4f;
	add_to_parent(id, parent);
	order.push_back(id);
	return true;
}

void SDTSweat::tick(int64_t p_tick) {
	tick_key = p_tick;
	std::vector<int> ids = order;
	for (int id : ids) {
		if (drops[id].alive) {
			step(id);
		}
	}
	std::vector<int> keep;
	for (int id : order) {
		if (drops[id].alive) {
			keep.push_back(id);
		} else {
			free_ids.push_back(id);
		}
	}
	order = std::move(keep);
}

PackedFloat32Array SDTSweat::get_draw(int c) const {
	PackedFloat32Array out;
	for (int id : order) {
		const Drop &d = drops[id];
		if (!d.alive || d.parent != c) {
			continue;
		}
		out.push_back(d.pos.x);
		out.push_back(d.pos.y);
		out.push_back(d.rot);
		out.push_back(d.sx);
		out.push_back(d.sy);
		out.push_back(d.alpha);
	}
	return out;
}

PackedInt32Array SDTSweat::parents_in_use() const {
	PackedInt32Array out;
	for (int i = 0; i < (int)containers.size(); i++) {
		if (!containers[i].drops.empty()) {
			out.push_back(i);
		}
	}
	return out;
}

void SDTSweat::clear() {
	for (int id : order) {
		kill(id);
	}
	for (int id : order) {
		free_ids.push_back(id);
	}
	order.clear();
}

int SDTSweat::count() const {
	return count_;
}
