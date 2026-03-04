package rtweekend

import "core:fmt"
import "core:math"
import "core:math/linalg"
import os "core:os/os2"
import "core:strings"
import "core:time"

FILENAME :: "image.ppm"

Color3 :: [3]f32
Point3 :: [3]f32
Vec3 :: [3]f32

Camera :: struct {
	pixel:               struct {
		first:   Point3,
		delta_x: Vec3,
		delta_y: Vec3,
	},
	center:              Point3,
	samples_per_pixel:   int,
	pixel_samples_scale: f32,
}

Image :: struct {
	width:        int,
	height:       int,
	aspect_ratio: f32,
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
	t:      f32,
	kind:   Ray_Intersection_Kind,
}

Sphere :: struct {
	center: Point3,
	radius: f32,
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
	image.height = int(f32(image.width) / image.aspect_ratio)

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
	viewport_height: f32 = 2
	viewport_width := viewport_height * (f32(image.width) / f32(image.height))
	viewport_x: Vec3
	viewport_x.x = viewport_width
	viewport_y: Vec3
	viewport_y.y = -viewport_height

	camera: Camera
	camera.pixel = {
		delta_x = viewport_x / f32(image.width),
		delta_y = viewport_y / f32(image.height),
	}
	camera.samples_per_pixel = 10
	camera.pixel_samples_scale = 1 * f32(camera.samples_per_pixel)

	focal_length: f32 = 1
	viewport_upper_left :=
		camera.center - Vec3{0, 0, focal_length} - viewport_x / 2 - viewport_y / 2
	camera.pixel.first = viewport_upper_left + 0.5 * (camera.pixel.delta_x + camera.pixel.delta_y)

	spheres := [?]Sphere {
		{center = Point3{0, 0, -1}, radius = 0.5},
		{center = Point3{0, -100.5, -1}, radius = 100},
	}

	// Render image
	for i in 0 ..< image.height {
		fmt.printf("\rLines remaining: %v", image.height - i, flush = false)

		for j in 0 ..< image.width {
			ray := Ray {
				origin    = camera.center,
				direction = camera.pixel.first + (f32(j) * camera.pixel.delta_x) + (f32(i) * camera.pixel.delta_y) - camera.center,
			}
			intersection: Ray_Intersection
			pixel: Color3

			tmin: f32 = 0
			tmax := math.INF_F32

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
				if (root <= tmin || root >= tmax) {
					root = (h + discriminant_sqrt) / a
					if (root <= tmin || root >= tmax) {
						continue
					}
				}

				// Intersection closest so far set to upper limit
				tmax, intersection.t = root, root
				intersection.point = ray.origin + intersection.t * ray.direction
				intersection.normal = (intersection.point - sphere.center) / sphere.radius

				// If normal and ray have opposite directions
				if linalg.dot(intersection.normal, ray.direction) < 0 {
					intersection.kind = .NORMAL_OPPOSITE
				} else {
					intersection.kind = .NORMAL_ALIGNED
				}
			}

			#partial switch intersection.kind {
			case .NO_HIT:
				normalized_ray := linalg.vector_normalize(ray.direction)
				t := (normalized_ray.y + 1) * 0.5

				// Lerp
				pixel = (1 - t) * Color3{1, 1, 1} + t * Color3{0.5, 0.7, 1}
			case:
				pixel = (intersection.normal + Color3{1, 1, 1}) * 0.5
			// case .NORMAL_ALIGNED:
			// case .NORMAL_OPPOSITE:
			}

			assert(
				0 < pixel.r &&
				pixel.r <= 1 &&
				0 < pixel.g &&
				pixel.g <= 1 &&
				0 < pixel.b &&
				pixel.b <= 1,
			)

			pixel *= 255

			fmt.sbprintln(&builder, int(pixel.r), int(pixel.g), int(pixel.b))
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
