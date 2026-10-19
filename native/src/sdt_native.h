#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/color.hpp>

#include <vector>

using namespace godot;

// Static helpers for the hottest paths of the game simulation, callable from GDScript as SDTNative.xxx(...).
class SDTNative : public Object {
	GDCLASS(SDTNative, Object)

protected:
	static void _bind_methods();

public:
	// Strand.renderStrand (with generateInterpolationPoints): builds the strand's drawing as one vertex-coloured
	// triangle mesh. Returns [points: PackedVector2Array, colors: PackedColorArray, indices: PackedInt32Array].
	static Array build_strand(const PackedVector2Array &p_pos, const PackedFloat32Array &p_thickness,
			const PackedFloat32Array &p_density, const PackedByteArray &p_has_stored,
			const PackedVector2Array &p_stored, const Color &p_rgb, double p_alpha, double p_max_interp_dist);

	// FlashDisplayObject._hit_shape (shape-flag hit testing) over the GDScript display tree: p is in obj's local
	// space, hb_gen the current FlashDisplayObject.hb_gen. Mirrors FlashSprite / FlashShape; other object types
	// (Graphics, text fields, bitmaps) call back into their GDScript _hit_shape.
	static bool hit_shape(Object *p_obj, const Vector2 &p_point, int64_t p_hb_gen);
	// hit_shape skipping one object of the tree (and its subtree).
	static bool hit_shape_excluding(Object *p_obj, const Vector2 &p_point, int64_t p_hb_gen, Object *p_exclude);
	// Shape hit test against obj's tree flattened once per tick (tick: the caller's tick counter), without Sweat
	// droplets: for many tests of the same object within one tick.
	static bool hit_flat(Object *p_obj, const Vector2 &p_point, int64_t p_tick);
};

// Shared with the fluid simulation (fluids.cpp).
struct StrandMesh {
	std::vector<godot::Vector2> points;
	std::vector<godot::Color> colors;
	std::vector<int32_t> indices;
};

// Appends one strand (link positions, thicknesses, densities; optional stored inter points) to mesh.
void sdt_append_strand_mesh(StrandMesh &mesh, const godot::Vector2 *pos, const float *thick, const float *dens,
		const uint8_t *has_stored, const godot::Vector2 *stored, int n, const godot::Color &rgb, double alpha,
		double max_interp_dist);

// Shape hit test of obj at p (obj's local space) against obj's tree flattened once per tick, without Sweat.
bool sdt_hit_flat(godot::Object *obj, const godot::Vector2 &p, int64_t tick);

// Bounds (obj's local space) of the shapes in obj's tree flattened for this tick, without Sweat.
godot::Rect2 sdt_flat_bounds(godot::Object *obj, int64_t tick);
