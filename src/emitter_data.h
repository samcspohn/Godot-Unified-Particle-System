#ifndef EMITTER_DATA_H
#define EMITTER_DATA_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class EmitterData : public RefCounted {
	GDCLASS(EmitterData, RefCounted)

private:
	bool active;
	Vector3 position;
	int template_id;
	double size_multiplier;
	double emit_rate;
	double speed_scale;
	double velocity_boost;

protected:
	static void _bind_methods();

public:
	EmitterData();
	~EmitterData();

	// Initialize with parameters
	void init(bool p_active = false, const Vector3 &p_position = Vector3(),
			  int p_template_id = -1, double p_size_multiplier = 1.0,
			  double p_emit_rate = 0.05, double p_speed_scale = 1.0,
			  double p_velocity_boost = 0.0);

	// Getters
	bool get_active() const;
	Vector3 get_position() const;
	int get_template_id() const;
	double get_size_multiplier() const;
	double get_emit_rate() const;
	double get_speed_scale() const;
	double get_velocity_boost() const;

	// Setters
	void set_active(bool p_active);
	void set_position(const Vector3 &p_position);
	void set_template_id(int p_template_id);
	void set_size_multiplier(double p_size_multiplier);
	void set_emit_rate(double p_emit_rate);
	void set_speed_scale(double p_speed_scale);
	void set_velocity_boost(double p_velocity_boost);
};

} // namespace godot

#endif // EMITTER_DATA_H