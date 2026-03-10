package rtweekend

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

FILENAME :: "image.ppm"
F64_NEAR_ZERO :: 1e-8

Color3 :: [3]f64
Point3 :: [3]f64
Vec3 :: [3]f64

// PPM image
Image :: struct {
	buf:          []u8, // Buffer into which to allocate image
	width:        int,
	height:       int,
	aspect_ratio: f64,
}

// Miscellaneous configuration values
Config :: struct {
	pixel_samples_scale: f64, // Color scale factor for a sum of pixel samples
	samples_per_pixel:   int, // Count of random samples for each pixel
	defocus_angle:       f64, // Variation angle of rays through each pixel
	focus_distance:      f64, // Distance from Camera.lookfrom point to plane of perfect focus
	max_depth:           int, // Maximum number of ray bounces into scene
}

// Camera from which rays originate
Camera :: struct {
	center:   Point3,
	lookfrom: Point3,
	lookat:   Point3,
	vup:      Vec3, // also used for rotation
	vfov:     f64, // vertical field of view
}

// Viewport into which to map image pixels
Viewport :: struct {
	u:           Vec3, // x-axis viewport vector
	v:           Vec3, // y-axis viewport vector
	delta:       struct {
		u: Vec3, // x-axis pixel delta vector
		v: Vec3, // y-axis pixel delta vector
	},
	first_pixel: Point3, // 0th pixel
	width:       f64,
	height:      f64,
}

Material_Kind :: enum {
	LAMBERTIAN,
	METALLIC,
	DIELETRIC,
}
Material :: struct {
	albedo:           Color3,
	fuzz:             f64,
	refraction_index: f64,
	kind:             Material_Kind,
}

Ray :: struct {
	origin:    Point3,
	direction: Vec3,
}

Ray_Intersection_Data :: struct {
	point:          Point3,
	normal:         Vec3,
	material:       ^Material,
	is_ray_outward: bool,
	has_hit:        bool,
}

Object :: struct {
	center:   Point3,
	radius:   f64,
	material: ^Material,
}

main :: proc() {
	// Set random seed on debug or when explicitly passed
	RANDOM_SEED: u64 : #config(RANDOM_SEED, 0)
	when ODIN_DEBUG || RANDOM_SEED > 0 {
		state := rand.create(RANDOM_SEED)
		context.random_generator = rand.default_random_generator(&state)
	}

	// Setup
	file, io_err := os.create(FILENAME)
	if io_err != nil {
		fmt.eprintfln("Error creating/opening %v: %v", FILENAME, io_err)
		return
	}
	defer os.close(file)

	// Initialize image
	image: Image
	{
		image = {
			aspect_ratio = 16.0 / 9.0,
			width        = 400,
		}
		image.height = int(f64(image.width) / image.aspect_ratio)

		line_len := 12
		alloc_err: mem.Allocator_Error
		image.buf, alloc_err = make(
			[]u8,
			line_len * image.height * image.width + 128,
		)
		if alloc_err != nil {
			fmt.eprintln("Error allocating buffer for image:", alloc_err)
			return
		}
	}
	defer delete(image.buf)

	builder := strings.builder_from_bytes(image.buf[:])
	fmt.sbprintln(&builder, "P3") // ASCII
	fmt.sbprintln(&builder, image.width)
	fmt.sbprintln(&builder, image.height)
	fmt.sbprintln(&builder, "255") // max color

	// Initialize config
	config: Config
	{
		config = {
			samples_per_pixel = 100,
			defocus_angle     = 0,
			focus_distance    = 10,
			max_depth         = 50,
		}
		config.pixel_samples_scale = 1 / f64(config.samples_per_pixel)
	}

	// Initialize camera with right-handed coordinates
	camera: Camera
	{
		camera = {
			lookfrom = {0, 0, 0},
			lookat   = {0, 0, -1},
			vup      = {0, 1, 0},
			vfov     = math.PI / 2,
		}
		camera.center = camera.lookfrom
	}

	// Calculate basis vectors to set viewport coordinates
	basis_w := linalg.normalize(camera.lookfrom - camera.lookat)
	basis_u := linalg.normalize(linalg.cross(camera.vup, basis_w))
	basis_v := linalg.cross(basis_w, basis_u)

	// Initialize viewport and convert to computer coordinates
	viewport: Viewport
	viewport.height = 2 * math.tan(camera.vfov / 2) * config.focus_distance
	viewport.width = viewport.height * (f64(image.width) / f64(image.height))
	viewport.u = viewport.width * basis_u
	viewport.v = viewport.height * -(basis_v)
	viewport.delta = {
		u = viewport.u / f64(image.width),
		v = viewport.v / f64(image.height),
	}

	// Get first pixel of viewport
	viewport_upper_left :=
		camera.center -
		config.focus_distance * basis_w -
		viewport.u / 2 -
		viewport.v / 2
	viewport.first_pixel =
		viewport_upper_left + 0.5 * (viewport.delta.u + viewport.delta.v)

	defocus_radius :=
		config.focus_distance * math.tan(config.defocus_angle / 2)
	defocus_disk_u := basis_u * defocus_radius
	defocus_disk_v := basis_v * defocus_radius

	// Materials
	ground := Material {
		kind   = .LAMBERTIAN,
		albedo = {0.8, 0.8, 0},
	}
	center_sphere := Material {
		kind   = .LAMBERTIAN,
		albedo = {0.1, 0.2, 0.5},
	}
	left_sphere := Material {
		kind             = .DIELETRIC,
		refraction_index = 1.5,
	}
	bubble := Material {
		kind             = .DIELETRIC,
		refraction_index = 1 / left_sphere.refraction_index,
	}
	right_sphere := Material {
		kind   = .METALLIC,
		albedo = {0.8, 0.6, 0.2},
		fuzz   = 1,
	}

	// Objects to be raytraced
	world := [?]Object {
		{center = Point3{0, -100.5, -1}, radius = 100, material = &ground},
		{center = Point3{0, 0, -1.2}, radius = 0.5, material = &center_sphere},
		{center = Point3{-1, 0, -1}, radius = 0.5, material = &left_sphere},
		{center = Point3{-1, 0, -1}, radius = 0.4, material = &bubble},
		{center = Point3{1, 0, -1}, radius = 0.5, material = &right_sphere},
	}

	// Benchmark at the end
	start := time.now()

	// Render image
	// TODO: multithread this
	for y in 0 ..< image.height {
		fmt.printf(
			"\rProgress: [% 3d/% 3d] ",
			y + 1,
			image.height,
			flush = false,
		)

		for x in 0 ..< image.width {
			sampled_pixel: Color3

			for _ in 0 ..< config.samples_per_pixel {
				offset := Vec3{rand.float64() - 0.5, rand.float64() - 0.5, 0}
				pixel_sample :=
					viewport.first_pixel +
					((f64(x) + offset.x) * viewport.delta.u) +
					((f64(y) + offset.y) * viewport.delta.v)

				// Initialize ray from camera center or random point in defocus disk
				ray: Ray
				if config.defocus_angle <= 0 {
					ray.origin = camera.center
				} else {
					point: Point3
					for {
						point = {
							rand.float64_range(-1, 1),
							rand.float64_range(-1, 1),
							0,
						}
						if linalg.length2(point) < 1 {
							break
						}
					}
					ray.origin =
						camera.center +
						(point.x * defocus_disk_u) +
						(point.y * defocus_disk_v)
				}
				ray.direction = pixel_sample - ray.origin

				color := get_ray_color(
					ray,
					max_depth = config.max_depth,
					world = world[:],
				)
				sampled_pixel += color
			}

			scaled_sampled_pixel := sampled_pixel * config.pixel_samples_scale
			gamma_corrected_pixel: Color3
			for pixel, index in scaled_sampled_pixel {
				if pixel > 0 {
					gamma_corrected_pixel[index] = math.sqrt(pixel)
				}
			}
			pixel_color := linalg.to_int(
				linalg.clamp(gamma_corrected_pixel, 0, 0.999) * 256,
			)
			fmt.sbprintln(
				&builder,
				pixel_color.r,
				pixel_color.g,
				pixel_color.b,
			)
		}
	}
	fmt.println()

	builder_len := strings.builder_len(builder)
	if _, err := os.write(file, image.buf[:builder_len]); err != nil {
		fmt.eprintfln("Error writing to %v: %v", FILENAME, err)
		return
	}

	fmt.printfln("%v: %M written", FILENAME, builder_len)
	fmt.println("Elapsed time:", time.since(start))
}

get_ray_color :: proc(
	ray: Ray,
	tmin: f64 = 0.001, // NOTE: avoid shadow acne
	tmax := math.INF_F64,
	max_depth := 10,
	world: []Object,
) -> (
	out: Color3,
) {
	if max_depth <= 0 {
		return
	}

	intersection_data: Ray_Intersection_Data
	tmax := tmax

	// Detect intersections
	for object in world {
		distance := object.center - ray.origin
		a := linalg.length2(ray.direction)
		c := linalg.length2(distance) - object.radius * object.radius
		h := linalg.dot(ray.direction, distance)
		discriminant := h * h - a * c

		// Check for intersections
		if discriminant < 0 {
			continue
		}

		discriminant_sqrt := math.sqrt(discriminant)
		root := (h - discriminant_sqrt) / a
		if !(tmin < root && root < tmax) {
			root = (h + discriminant_sqrt) / a
			if !(tmin < root && root < tmax) {
				continue
			}
		}

		// Closest intersection so far
		tmax = root
		intersection_data.material = object.material
		intersection_data.point = ray.origin + root * ray.direction
		intersection_data.normal =
			(intersection_data.point - object.center) / object.radius
		intersection_data.has_hit = true
	}

	if linalg.dot(ray.direction, intersection_data.normal) <= 0 {
		intersection_data.is_ray_outward = true
	} else {
		intersection_data.normal = -intersection_data.normal
	}

	if !intersection_data.has_hit {
		direction := linalg.vector_normalize(ray.direction)
		out = linalg.lerp(
			Color3{1, 1, 1},
			Color3{0.5, 0.7, 1},
			(direction.y + 1) * 0.5,
		)
		return
	}

	// Scatter ray
	diffused_ray := Ray {
		origin = intersection_data.point,
	}
	switch intersection_data.material.kind {
	case .LAMBERTIAN:
		direction := random_unit_vector() + intersection_data.normal
		if linalg.all(
			linalg.less_than_array(linalg.abs(direction), F64_NEAR_ZERO),
		) {
			direction = intersection_data.normal
		}

		diffused_ray.direction = direction
	case .METALLIC:
		direction := reflect(ray.direction, intersection_data.normal)
		direction =
			linalg.normalize(direction) +
			(intersection_data.material.fuzz * random_unit_vector())

		if (linalg.dot(direction, intersection_data.normal) <= 0) {
			return
		}

		diffused_ray.direction = direction
	case .DIELETRIC:
		intersection_data.material.albedo = Color3{1, 1, 1}

		refraction_index: f64
		if intersection_data.is_ray_outward {
			refraction_index =
				(1 / intersection_data.material.refraction_index)
		} else {
			refraction_index = intersection_data.material.refraction_index
		}

		unit_direction := linalg.normalize(ray.direction)

		cos_theta := min(
			linalg.dot(-unit_direction, intersection_data.normal),
			1,
		)
		sin_theta := math.sqrt(1 - cos_theta * cos_theta)

		cannot_refract := refraction_index * sin_theta > 1

		direction: Vec3
		// Reflect ray or else refract
		if (cannot_refract ||
			   reflectance(cos_theta, refraction_index) > rand.float64()) {
			direction = reflect(unit_direction, intersection_data.normal)
		} else {
			cos_theta := min(
				linalg.dot(-unit_direction, intersection_data.normal),
				1,
			)
			perpendicular_ray :=
				refraction_index *
				(unit_direction + cos_theta * intersection_data.normal)
			parallel_ray :=
				-math.sqrt(abs(1 - linalg.length2(perpendicular_ray))) *
				intersection_data.normal

			direction = perpendicular_ray + parallel_ray
		}
		diffused_ray.direction = direction
	}

	return(
		intersection_data.material.albedo *
		get_ray_color(diffused_ray, max_depth = max_depth - 1, world = world) \
	)
}

// TODO: Seems dumb, find a better way
random_unit_vector :: proc() -> (out: Vec3) {
	for {
		for &v in out do v = rand.float64_range(-1, 1)
		out_len2 := linalg.length2(out)

		// NOTE: or math.F64_MIN
		if 1e-160 < out_len2 && out_len2 <= 1 {
			out /= math.sqrt(out_len2)
			return
		}
	}
}

reflect :: proc(direction, normal: Vec3) -> Vec3 {
	return direction - 2 * linalg.dot(direction, normal) * normal
}

// Schlick's approximation for reflectance
reflectance :: proc(cos_theta, refraction_index: f64) -> f64 {
	r := (1 - refraction_index) / (1 + refraction_index)
	r *= r
	return r + (1 - r) * math.pow(1 - cos_theta, 5)
}
