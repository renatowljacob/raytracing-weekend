package rtweekend

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"

FILENAME :: "image.ppm"
F64_NEAR_ZERO :: 1e-8

Color3 :: [3]f64
Point3 :: [3]f64
Vec3 :: [3]f64

Camera :: struct {
	pixel:               struct {
		first:   Point3,
		delta_x: Vec3,
		delta_y: Vec3,
	},
	center:              Point3,
	pixel_samples_scale: f64,
	samples_per_pixel:   int,
	max_depth:           int,
}

Image :: struct {
	width:        int,
	height:       int,
	aspect_ratio: f64,
}

Material_Kind :: enum i8 {
	LAMBERTIAN,
	METALLIC,
}
Material :: struct {
	albedo: Color3,
	kind:   Material_Kind,
}

Ray :: struct {
	origin:    Point3,
	direction: Vec3,
}

// Ray_Intersection_Kind :: enum i8 {
// 	NO_HIT,
// 	NORMAL_ALIGNED,
// 	NORMAL_OPPOSITE,
// }
Ray_Intersection :: struct {
	point:    Point3,
	normal:   Vec3,
	material: ^Material,
	has_hit:  bool,
}

Object :: struct {
	center:   Point3,
	radius:   f64,
	material: ^Material,
}

main :: proc() {
	start := time.now()

	// Setup
	file, io_err := os.create(FILENAME)
	if io_err != nil {
		fmt.eprintfln("Error creating/opening %v: %v", FILENAME, io_err)
		return
	}
	defer os.close(file)

	image: Image
	image.aspect_ratio = 16.0 / 9.0
	image.width = 400
	image.height = int(f64(image.width) / image.aspect_ratio)

	max_line_len := 12
	buf, alloc_err := make([]u8, max_line_len * image.width * image.height + 128)
	if alloc_err != nil {
		fmt.eprintln("Error allocating buffer:", alloc_err)
		return
	}
	defer delete(buf)

	builder := strings.builder_from_bytes(buf[:])

	fmt.sbprintln(&builder, "P3")
	fmt.sbprintln(&builder, image.width)
	fmt.sbprintln(&builder, image.height)
	fmt.sbprintln(&builder, "255")

	// Test this with aspect_ratio later
	viewport_height: f64 = 2
	viewport_width := viewport_height * (f64(image.width) / f64(image.height))
	viewport_x: Vec3
	viewport_x.x = viewport_width
	viewport_y: Vec3
	viewport_y.y = -viewport_height

	camera: Camera
	camera.pixel = {
		delta_x = viewport_x / f64(image.width),
		delta_y = viewport_y / f64(image.height),
	}
	camera.samples_per_pixel = 100
	camera.pixel_samples_scale = 1 / f64(camera.samples_per_pixel)
	camera.max_depth = 50

	focal_length: f64 = 1
	viewport_upper_left :=
		camera.center - Vec3{0, 0, focal_length} - viewport_x / 2 - viewport_y / 2
	camera.pixel.first = viewport_upper_left + 0.5 * (camera.pixel.delta_x + camera.pixel.delta_y)

	ground := Material {
		kind   = .LAMBERTIAN,
		albedo = {0.8, 0.8, 0},
	}
	center_sphere := Material {
		kind   = .LAMBERTIAN,
		albedo = {0.1, 0.2, 0.5},
	}
	left_sphere := Material {
		kind   = .METALLIC,
		albedo = {0.8, 0.8, 0.8},
	}
	right_sphere := Material {
		kind   = .METALLIC,
		albedo = {0.8, 0.6, 0.2},
	}

	world := [?]Object {
		{center = Point3{0, -100.5, -1}, radius = 100, material = &ground},
		{center = Point3{0, 0, -1.2}, radius = 0.5, material = &center_sphere},
		{center = Point3{-1, 0, -1}, radius = 0.5, material = &left_sphere},
		{center = Point3{1, 0, -1}, radius = 0.5, material = &right_sphere},
	}

	// Render image
	for y in 0 ..< image.height {
		fmt.printf("\rLines remaining: %v ", image.height - y, flush = false)

		for x in 0 ..< image.width {
			sampled_pixel: Color3

			for _ in 0 ..< camera.samples_per_pixel {
				offset := Vec3{rand.float64() - 0.5, rand.float64() - 0.5, 0}
				pixel_sample :=
					camera.pixel.first +
					((f64(x) + offset.x) * camera.pixel.delta_x) +
					((f64(y) + offset.y) * camera.pixel.delta_y)
				ray: Ray
				ray.origin = camera.center
				ray.direction = pixel_sample - ray.origin

				color := get_ray_color(
					ray,
					tmin = 0.001,
					max_depth = camera.max_depth,
					world = world[:],
				)
				sampled_pixel += linalg.clamp(color, 0, 1)
			}

			scaled_sampled_pixel := sampled_pixel * camera.pixel_samples_scale
			pixel_color := linalg.to_int(linalg.sqrt(scaled_sampled_pixel) * 255.999) // Linear to gamma 2 space

			fmt.sbprintln(&builder, pixel_color.r, pixel_color.g, pixel_color.b)
		}
	}
	fmt.println()

	builder_len := strings.builder_len(builder)
	if _, err := os.write(file, buf[:builder_len]); err != nil {
		fmt.eprintfln("Error writing to %v: %v", FILENAME, err)
		return
	}

	fmt.printfln("%v: %M written", FILENAME, builder_len)
	fmt.println("Elapsed time:", time.since(start))
}

// BUG: For some reason colored objects are darker than they should be.
// Metallic objects also have a weird noise
get_ray_color :: proc(
	ray: Ray,
	tmin: f64 = 0,
	tmax := math.INF_F64,
	max_depth := 10,
	world: []Object,
) -> (
	color: Color3,
) {
	if max_depth <= 0 {
		return
	}

	intersection: Ray_Intersection
	tmax := tmax

	// Detect closest intersection
	// TODO: multithread this
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

		discriminant_sqrt := linalg.sqrt(discriminant)
		root := (h - discriminant_sqrt) / a
		if root <= tmin || root >= tmax {
			root = (h + discriminant_sqrt) / a
			if root <= tmin || root >= tmax {
				continue
			}
		}

		tmax = root
		intersection.material = object.material
		intersection.point = ray.origin + root * ray.direction
		intersection.normal = linalg.normalize(
			(intersection.point - object.center) / object.radius,
		)
		intersection.has_hit = true
	}

	if !intersection.has_hit {
		direction := linalg.vector_normalize(ray.direction)
		color = linalg.lerp(Color3{1, 1, 1}, Color3{0.5, 0.7, 1}, (direction.y + 1) * 0.5)
		return
	}

	diffused_ray := Ray {
		origin = intersection.point,
	}
	switch intersection.material.kind {
	case .LAMBERTIAN:
		// TODO: Seems dumb, find a better way
		direction: Vec3
		for {
			direction = Vec3 {
				rand.float64_range(-1, 1),
				rand.float64_range(-1, 1),
				rand.float64_range(-1, 1),
			}
			direction_len2 := linalg.length2(direction)

			// NOTE: or 10e-160
			if direction_len2 >= math.F64_MIN && direction_len2 <= 1 {
				direction /= math.sqrt(direction_len2)
				break
			}
		}
		direction += intersection.normal

		if linalg.all(linalg.less_than_array(linalg.abs(direction), F64_NEAR_ZERO)) {
			direction = intersection.normal
		}

		diffused_ray.direction = direction
	case .METALLIC:
		// Reflect
		direction :=
			ray.direction -
			2 * (linalg.dot(ray.direction, intersection.normal)) * intersection.normal
		diffused_ray.direction = direction
	}

	return(
		intersection.material.albedo *
		get_ray_color(diffused_ray, max_depth = max_depth - 1, world = world) *
		0.5 \
	)
}
