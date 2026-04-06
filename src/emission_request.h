#ifndef EMISSION_REQUEST_H
#define EMISSION_REQUEST_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class EmissionRequest : public RefCounted {
	GDCLASS(EmissionRequest, RefCounted)

private:
	Vector3 position;
	Vector3 direction;
	int template_id;
	double size_multiplier;
	int count;
	double speed_mod;
	int random_seed;
	int prefix_offset;

protected:
	static void _bind_methods();

public:
	EmissionRequest();
	~EmissionRequest();

	// Initialize with parameters
	void init(const Vector3 &p_position, const Vector3 &p_direction, int p_template_id,
			  double p_size_multiplier, int p_count, double p_speed_mod, int p_random_seed);

	// Getters
	Vector3 get_position() const;
	Vector3 get_direction() const;
	int get_template_id() const;
	double get_size_multiplier() const;
	int get_count() const;
	double get_speed_mod() const;
	int get_random_seed() const;
	int get_prefix_offset() const;

	// Setters
	void set_position(const Vector3 &p_position);
	void set_direction(const Vector3 &p_direction);
	void set_template_id(int p_template_id);
	void set_size_multiplier(double p_size_multiplier);
	void set_count(int p_count);
	void set_speed_mod(double p_speed_mod);
	void set_random_seed(int p_random_seed);
	void set_prefix_offset(int p_prefix_offset);
};

} // namespace godot

#endif // EMISSION_REQUEST_H