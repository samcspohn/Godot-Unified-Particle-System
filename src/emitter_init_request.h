#ifndef EMITTER_INIT_REQUEST_H
#define EMITTER_INIT_REQUEST_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class EmitterInitRequest : public RefCounted {
	GDCLASS(EmitterInitRequest, RefCounted)

private:
	int id;
	int template_id;
	double size_multiplier;
	double emit_rate;
	double speed_scale;
	double velocity_boost;
	Vector3 position;

protected:
	static void _bind_methods();

public:
	EmitterInitRequest();
	~EmitterInitRequest();

	// Initialize with parameters
	void init(int p_id, int p_template_id, double p_size_multiplier,
			  double p_emit_rate, double p_speed_scale, double p_velocity_boost,
			  const Vector3 &p_position);

	// Getters
	int get_id() const;
	int get_template_id() const;
	double get_size_multiplier() const;
	double get_emit_rate() const;
	double get_speed_scale() const;
	double get_velocity_boost() const;
	Vector3 get_position() const;

	// Setters
	void set_id(int p_id);
	void set_template_id(int p_template_id);
	void set_size_multiplier(double p_size_multiplier);
	void set_emit_rate(double p_emit_rate);
	void set_speed_scale(double p_speed_scale);
	void set_velocity_boost(double p_velocity_boost);
	void set_position(const Vector3 &p_position);
};

} // namespace godot

#endif // EMITTER_INIT_REQUEST_H