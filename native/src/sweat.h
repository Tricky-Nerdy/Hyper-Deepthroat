#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform2d.hpp>

#include <vector>

using namespace godot;

// The sweat droplets (obj.Sweat) simulated in one place, as plain data. Body parts are "containers" registered by
// GDScript (Sweat.gd), which sends their stage transforms and accumulated rotations every tick; droplets slide over
// their shapes (per-tick flattened hit tests), merge, hop to neighbouring parts and drip off. GDScript draws each
// part's droplets with one node (get_draw).
class SDTSweat : public RefCounted {
	GDCLASS(SDTSweat, RefCounted)

public:
	struct Container {
		ObjectID obj;
		Transform2D to_stage, from_stage;
		float rot = 0.0f;           // sum of rotation_degrees up to the stage (the original's parentDown input)
		float own_rot = 0.0f;       // its own rotation_degrees
		std::vector<int> children;  // sprite children that are not droplets (Sweat.addToParent's parentChildren)
		std::vector<int> drops;     // droplets on it, in arrival order (sweatGroups)
		int64_t parent_key = 0;     // its display parent (instance id) and index there: a falling droplet stops
		int index = 0;              // checking parts drawn above its own
	};

	struct Drop {
		int parent = -1;
		int on_child = -1;     // container the droplet slides on; -1: its parent; -2: none (falling, stage space)
		std::vector<int> others; // parentsToCheck
		std::vector<int> children;
		bool alive = false, not_on_parent = false, attached = false, just_detached = false;
		Vector2 pos;           // in the parent's space (x, y)
		Vector2 local;         // in on_child's space (or the stage's)
		Vector2 speed, global, gvec, svec;
		int predict_toggle = 0;
		float predict_dist = 0.8f, last_velocity = 0.0f, velocity = NAN, mass = 0.1f, max_mass = 1.2f;
		float left_push = 0.0f, right_push = 0.0f;
		float alpha = 0.0f, sx = 1.0f, sy = 1.0f, rot = 0.0f;
	};

private:
	std::vector<Container> containers;
	std::vector<Drop> drops;
	std::vector<int> free_ids;
	std::vector<int> order; // droplet ids in creation order (tick order)
	int64_t tick_key = 0;
	int count_ = 0;

	bool hit(int c, Vector2 g) const;
	bool in_bounds(int c, Vector2 g) const;
	Vector2 to_global(const Drop &d, int c, Vector2 p) const; // c: container, -2: stage
	Vector2 from_global(int c, Vector2 g) const;
	Vector2 down_of(const Drop &d, int c) const;
	void add_to_parent(int id, int c);
	void jump_to_child(int id);
	void kill(int id);
	void step(int id);

protected:
	static void _bind_methods();

public:
	int add_container(Object *obj);
	void set_children(int c, const PackedInt32Array &children, int64_t parent_key, int index);
	void set_transforms(const Array &transforms, const PackedFloat32Array &rotations, const PackedFloat32Array &own);
	bool spawn(int parent, const Vector2 &p, const Vector2 &spread, const PackedInt32Array &others, int max_drops);
	void tick(int64_t tick);
	PackedFloat32Array get_draw(int c) const; // per droplet: x, y, rotation (degrees), scale x, scale y, alpha
	PackedInt32Array parents_in_use() const;
	void clear();
	int count() const;
};
