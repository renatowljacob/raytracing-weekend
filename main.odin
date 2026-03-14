package rtweekend

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

FILENAME :: "image.ppm"
LINE_LEN :: 12
THREAD_COUNT :: 8
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

Defocus_Disk :: struct {
	radius: f64,
	u:      Vec3, // horizontal radius
	v:      Vec3, // vertical radius
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

Object :: struct {
	center:   Point3,
	radius:   f64,
	material: ^Material,
}

World :: struct {
	objects:   []Object,
	materials: []Material,
	len:       int,
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

Progress :: struct {
	current: int,
	max:     int,
}

Shared_Data :: struct {
	// The sum of all builders for each line
	builder_total_len: ^int,
	image:             ^Image,
	config:            ^Config,
	camera:            ^Camera,
	viewport:          ^Viewport,
	defocus_disk:      ^Defocus_Disk,
	progress:          ^Progress,
	world:             ^World,
}
Thread_Data :: struct {
	shared: ^Shared_Data,
	id:     int,
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

	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.eprintln("Error setting up arena:", err)
	}
	arena_allocator := vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	// Initialize image
	image: Image
	{
		image = {
			aspect_ratio = 16.0 / 9.0,
			width        = 1200,
		}
		image.height = int(f64(image.width) / image.aspect_ratio)

		alloc_err: mem.Allocator_Error
		image.buf, alloc_err = make(
			[]u8,
			LINE_LEN * image.height * image.width + 128,
			arena_allocator,
		)
		if alloc_err != nil {
			fmt.eprintln("Error allocating buffer for image:", alloc_err)
			return
		}
	}

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
			defocus_angle     = math.PI / 300,
			focus_distance    = 10,
			max_depth         = 50,
		}
		config.pixel_samples_scale = 1 / f64(config.samples_per_pixel)
	}

	// Initialize camera with right-handed coordinates
	camera: Camera
	{
		camera = {
			lookfrom = {13, 2, 3},
			lookat   = {0, 0, 0},
			vup      = {0, 1, 0},
			vfov     = math.PI / 9,
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

	defocus_disk := Defocus_Disk {
		radius = config.focus_distance * math.tan(config.defocus_angle / 2),
	}
	defocus_disk.u = basis_u * defocus_disk.radius
	defocus_disk.v = basis_v * defocus_disk.radius

	MAX_OBJECTS :: 22 * 22 + 4
	materials := make([]Material, MAX_OBJECTS, arena_allocator)
	objects := make([]Object, MAX_OBJECTS, arena_allocator)
	world := World {
		materials = materials,
		objects   = objects,
	}

	// Ground
	append_world(
		&world,
		Material{kind = .LAMBERTIAN, albedo = Color3{0.5, 0.5, 0.5}},
		Object{center = Point3{0, -1000, 0}, radius = 1000},
	)
	for a in -11 ..< 11 {
		for b in -11 ..< 11 {
			// Smaller spheres
			random_material := rand.float64()
			center := Point3 {
				f64(a) + 0.9 * rand.float64(),
				0.2,
				f64(b) + 0.9 * rand.float64(),
			}

			if (linalg.length(center - Point3{4, 0.2, 0}) > 0.9) {
				small_sphere := Object {
					center = center,
					radius = 0.2,
				}
				small_sphere_material: Material
				switch random_material {
				case 0.0 ..< 0.8:
					// lambertian
					albedo := random_color() * random_color()
					small_sphere_material = Material {
						kind   = .LAMBERTIAN,
						albedo = albedo,
					}
				case 0.8 ..< 0.95:
					// metal
					albedo := random_color(0.5, 1)
					fuzz := rand.float64_range(0, 0.5)
					small_sphere_material = Material {
						kind   = .METALLIC,
						albedo = albedo,
						fuzz   = fuzz,
					}
				case:
					// glass
					small_sphere_material = Material {
						kind             = .DIELETRIC,
						refraction_index = 1.5,
					}
				}
				append_world(&world, small_sphere_material, small_sphere)
			}
		}
	}
	// Bigger spheres
	append_world(
		&world,
		Material{kind = .DIELETRIC, refraction_index = 1.5},
		Object{center = Point3{0, 1, 0}, radius = 1},
	)
	append_world(
		&world,
		Material{kind = .LAMBERTIAN, albedo = Color3{0.4, 0.2, 0.1}},
		Object{center = Point3{-4, 1, 0}, radius = 1},
	)
	append_world(
		&world,
		Material{kind = .METALLIC, albedo = Color3{0.7, 0.6, 0.5}, fuzz = 0},
		Object{center = Point3{4, 1, 0}, radius = 1},
	)

	builder_total_len := strings.builder_len(builder)
	progress := Progress {
		max = image.height,
	}

	threads: [THREAD_COUNT]^thread.Thread
	shared_data := Shared_Data {
		builder_total_len = &builder_total_len,
		camera            = &camera,
		config            = &config,
		defocus_disk      = &defocus_disk,
		image             = &image,
		progress          = &progress,
		viewport          = &viewport,
		world             = &world,
	}
	thread_data: [THREAD_COUNT]Thread_Data

	benchmark_start := time.now()
	for i in 0 ..< len(threads) {
		thread_data[i] = {
			shared = &shared_data,
			id     = i,
		}

		// Render image rows for each thread
		threads[i] = thread.create(render_world)
		threads[i].data = &thread_data[i]
		thread.start(threads[i])
	}
	defer {
		for i in 0 ..< len(threads) do thread.destroy(threads[i])
	}

	outer: for {
		time.sleep(time.Millisecond * 500)
		fmt.printf(
			"\rProgress: [% 3d/% 3d] ",
			progress.current,
			progress.max,
			flush = false,
		)

		for t in threads {
			if !thread.is_done(t) {
				continue outer
			}
		}
		break outer
	}
	thread.join_multiple(..threads[:])
	fmt.println()

	fmt.println(builder_total_len)
	if _, err := os.write(file, image.buf[:builder_total_len]); err != nil {
		fmt.eprintfln("Error writing to %v: %v", FILENAME, err)
		return
	}

	fmt.printfln("%v: %M written", FILENAME, builder_total_len)
	fmt.println("Elapsed time:", time.since(benchmark_start))
}

render_world :: proc(t: ^thread.Thread) {
	thread_data := cast(^Thread_Data)t.data
	camera := thread_data.shared.camera
	config := thread_data.shared.config
	defocus_disk := thread_data.shared.defocus_disk
	image := thread_data.shared.image
	progress := thread_data.shared.progress
	viewport := thread_data.shared.viewport
	world := thread_data.shared.world

	buf_offset := thread_data.shared.builder_total_len^
	bytes_per_line := image.width * LINE_LEN

	for y := thread_data.id; y < image.height; y += THREAD_COUNT {
		starting_byte := y * bytes_per_line + buf_offset
		finishing_byte := (y + 1) * bytes_per_line + buf_offset
		builder := strings.builder_from_slice(
			image.buf[starting_byte:finishing_byte],
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
						(point.x * defocus_disk.u) +
						(point.y * defocus_disk.v)
				}
				ray.direction = pixel_sample - ray.origin

				color := get_ray_color(
					ray,
					max_depth = config.max_depth,
					world = world.objects[:],
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
			fmt.sbprintf(
				&builder,
				"% 3d % 3d % 3d\n",
				pixel_color.r,
				pixel_color.g,
				pixel_color.b,
			)
		}

		sync.atomic_add(
			thread_data.shared.builder_total_len,
			strings.builder_len(builder),
		)
		sync.atomic_add(&progress.current, 1)
	}
}

append_world :: proc(world: ^World, material: Material, object: Object) {
	world.objects[world.len] = object
	world.materials[world.len] = material
	world.objects[world.len].material = &world.materials[world.len]
	world.len += 1
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

random_color :: proc(low: f64 = 0, high: f64 = 1) -> Color3 {
	return Color3 {
		rand.float64_range(low, high),
		rand.float64_range(low, high),
		rand.float64_range(low, high),
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
