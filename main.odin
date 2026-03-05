package rtweekend

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import os "core:os/os2"
import "core:strings"
import "core:time"

FILENAME :: "image.ppm"

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
	samples_per_pixel:   int,
	pixel_samples_scale: f64,
	max_depth:           int,
}

Image :: struct {
	width:        int,
	height:       int,
	aspect_ratio: f64,
}

Ray :: struct {
	origin:    Point3,
	direction: Vec3,
}

Ray_Intersection_Kind :: enum i8 {
	NO_HIT,
	NORMAL_ALIGNED,
	NORMAL_OPPOSITE,
}

Ray_Intersection :: struct {
	point:  Point3,
	normal: Vec3,
	t:      f64,
	kind:   Ray_Intersection_Kind,
}

Sphere :: struct {
	center: Point3,
	radius: f64,
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
	camera.max_depth = 10

	focal_length: f64 = 1
	viewport_upper_left :=
		camera.center - Vec3{0, 0, focal_length} - viewport_x / 2 - viewport_y / 2
	camera.pixel.first = viewport_upper_left + 0.5 * (camera.pixel.delta_x + camera.pixel.delta_y)

	spheres := [?]Sphere {
		{center = Point3{0, 0, -1}, radius = 0.5},
		{center = Point3{0, -100.5, -1}, radius = 100},
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

				pixel := get_ray_color(
					ray,
					tmin = 0.001,
					max_depth = camera.max_depth,
					spheres = spheres[:],
				)
				pixel = {clamp(pixel.r, 0, 1), clamp(pixel.g, 0, 1), clamp(pixel.b, 0, 1)}
				sampled_pixel += pixel

			}

			sampled_pixel *= camera.pixel_samples_scale * 255
			fmt.sbprintln(
				&builder,
				int(sampled_pixel.r),
				int(sampled_pixel.g),
				int(sampled_pixel.b),
			)
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

get_ray_color :: proc(
	ray: Ray,
	tmin: f64 = 0,
	tmax := math.INF_F64,
	max_depth := 10,
	spheres: []Sphere,
) -> Color3 {
	intersection: Ray_Intersection
	tmax := tmax

	if max_depth <= 0 do return Color3{0, 0, 0}

	// Detect closest intersection
	for sphere in spheres {
		distance := sphere.center - ray.origin
		a := linalg.length2(ray.direction)
		c := linalg.length2(distance) - sphere.radius * sphere.radius
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

		// Intersection closest so far set to upper limit
		tmax, intersection.t = root, root
		intersection.point = ray.origin + intersection.t * ray.direction
		intersection.normal = (intersection.point - sphere.center) / sphere.radius

		// If normal and ray have opposite directions
		intersection.kind =
			.NORMAL_ALIGNED if linalg.dot(intersection.normal, ray.direction) > 0 else .NORMAL_OPPOSITE

	}

	#partial switch intersection.kind {
	case .NO_HIT:
		normalized_ray := linalg.vector_normalize(ray.direction)
		t := (normalized_ray.y + 1) * 0.5
		return linalg.lerp(Color3{1, 1, 1}, Color3{0.5, 0.7, 1}, t)
	case:
		// Seems dumb, find a better way later
		reflected_ray: Vec3
		for {
			reflected_ray = Vec3 {
				rand.float64_range(-1, 1),
				rand.float64_range(-1, 1),
				rand.float64_range(-1, 1),
			}
			reflected_ray_len2 := linalg.length2(reflected_ray)

			if reflected_ray_len2 >= math.F64_MIN && reflected_ray_len2 <= 1 {
				reflected_ray /= linalg.sqrt(reflected_ray_len2)
				break
			}
		}

		reflected_ray =
			reflected_ray if linalg.dot(intersection.normal, reflected_ray) > 0 else -reflected_ray

		return(
			get_ray_color(
				Ray{intersection.point, reflected_ray},
				max_depth = max_depth - 1,
				spheres = spheres,
			) *
			0.5 \
		)
	}
	// case .NORMAL_ALIGNED:
	// case .NORMAL_OPPOSITE:
}
