import argparse
import importlib.util
import json
import math
import sys
import types
from collections import Counter, defaultdict, deque
from pathlib import Path

from PIL import Image, ImageDraw


class Vector:
    def __init__(self, values=()):
        values = tuple(values)
        self.values = values if values else (0.0, 0.0, 0.0)

    @property
    def x(self):
        return self.values[0]

    @property
    def y(self):
        return self.values[1]

    @property
    def z(self):
        return self.values[2]

    @property
    def length_squared(self):
        return self.dot(self)

    def normalized(self):
        length = math.sqrt(self.length_squared)
        return self / length if length else Vector()

    def dot(self, other):
        other = Vector(other)
        return sum(first * second for first, second in zip(self, other))

    def cross(self, other):
        other = Vector(other)
        return Vector(
            (
                self.y * other.z - self.z * other.y,
                self.z * other.x - self.x * other.z,
                self.x * other.y - self.y * other.x,
            )
        )

    def lerp(self, other, factor):
        return self + (Vector(other) - self) * factor

    def __iter__(self):
        return iter(self.values)

    def __add__(self, other):
        other = Vector(other)
        return Vector(first + second for first, second in zip(self, other))

    def __sub__(self, other):
        other = Vector(other)
        return Vector(first - second for first, second in zip(self, other))

    def __mul__(self, scalar):
        return Vector(value * scalar for value in self)

    def __rmul__(self, scalar):
        return self * scalar

    def __truediv__(self, scalar):
        return Vector(value / scalar for value in self)

    def __neg__(self):
        return Vector(-value for value in self)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--builder", required=True)
    parser.add_argument("--output-root", required=True)
    return parser.parse_args()


def load_builder(path):
    mathutils = types.ModuleType("mathutils")
    mathutils.Vector = Vector
    sys.modules["mathutils"] = mathutils
    sys.modules["bmesh"] = types.ModuleType("bmesh")
    sys.modules["bpy"] = types.ModuleType("bpy")
    spec = importlib.util.spec_from_file_location("bear_cage_builder", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def generate(module):
    vertices, faces = module.build_torso_vertices_faces()
    loops = module.boundary_loops(faces)
    shoulders = []
    for loop in loops:
        center = sum((Vector(vertices[index]) for index in loop), start=Vector()) / len(loop)
        if len(loop) == module.LIMB_SEGMENTS and abs(center.x) > 0.25:
            shoulders.append((center.x, loop))
    if len(shoulders) != 2:
        raise RuntimeError(f"Expected two shoulder loops, got {[(center, len(loop)) for center, loop in shoulders]}")
    limb_reports = []
    for center_x, loop in sorted(shoulders):
        limb_reports.append(module.add_limb(vertices, faces, loop, -1.0 if center_x < 0.0 else 1.0))
    used = sorted({index for face in faces for index in face})
    remap = {old: new for new, old in enumerate(used)}
    return [vertices[index] for index in used], [tuple(remap[index] for index in face) for face in faces], limb_reports


def topology(vertices, faces):
    edges = Counter()
    adjacency = defaultdict(set)
    for face in faces:
        for index, first in enumerate(face):
            second = face[(index + 1) % len(face)]
            edge = tuple(sorted((first, second)))
            edges[edge] += 1
            adjacency[first].add(second)
            adjacency[second].add(first)
    remaining = set(range(len(vertices)))
    components = 0
    while remaining:
        components += 1
        queue = deque([next(iter(remaining))])
        while queue:
            vertex = queue.popleft()
            if vertex not in remaining:
                continue
            remaining.remove(vertex)
            queue.extend(adjacency[vertex] & remaining)
    return {
        "vertices": len(vertices),
        "edges": len(edges),
        "faces": len(faces),
        "quads": sum(len(face) == 4 for face in faces),
        "triangles": sum(len(face) == 3 for face in faces),
        "ngons": sum(len(face) > 4 for face in faces),
        "boundaryEdges": sum(count == 1 for count in edges.values()),
        "nonmanifoldEdges": sum(count > 2 for count in edges.values()),
        "components": components,
    }


def catmull_clark(vertices, faces):
    points = [Vector(vertex) for vertex in vertices]
    face_points = [sum((points[index] for index in face), start=Vector()) / len(face) for face in faces]
    edge_faces = defaultdict(list)
    vertex_faces = defaultdict(list)
    vertex_edges = defaultdict(set)
    for face_index, face in enumerate(faces):
        for vertex in face:
            vertex_faces[vertex].append(face_index)
        for index, first in enumerate(face):
            second = face[(index + 1) % len(face)]
            edge = tuple(sorted((first, second)))
            edge_faces[edge].append(face_index)
            vertex_edges[first].add(edge)
            vertex_edges[second].add(edge)

    new_vertices = []
    old_vertex_indices = {}
    for vertex_index, point in enumerate(points):
        boundary_neighbors = []
        for edge in vertex_edges[vertex_index]:
            if len(edge_faces[edge]) == 1:
                boundary_neighbors.append(edge[0] if edge[1] == vertex_index else edge[1])
        if len(boundary_neighbors) == 2:
            value = point * 0.75 + (points[boundary_neighbors[0]] + points[boundary_neighbors[1]]) * 0.125
        else:
            linked_faces = vertex_faces[vertex_index]
            count = len(linked_faces)
            face_average = sum((face_points[index] for index in linked_faces), start=Vector()) / count
            edge_average = sum(
                ((points[edge[0]] + points[edge[1]]) * 0.5 for edge in vertex_edges[vertex_index]),
                start=Vector(),
            ) / len(vertex_edges[vertex_index])
            value = (face_average + edge_average * 2.0 + point * (count - 3.0)) / count
        old_vertex_indices[vertex_index] = len(new_vertices)
        new_vertices.append(tuple(value))

    edge_indices = {}
    for edge, linked_faces in edge_faces.items():
        if len(linked_faces) == 2:
            value = (points[edge[0]] + points[edge[1]] + face_points[linked_faces[0]] + face_points[linked_faces[1]]) / 4.0
        else:
            value = (points[edge[0]] + points[edge[1]]) * 0.5
        edge_indices[edge] = len(new_vertices)
        new_vertices.append(tuple(value))

    face_indices = []
    for value in face_points:
        face_indices.append(len(new_vertices))
        new_vertices.append(tuple(value))

    new_faces = []
    for face_index, face in enumerate(faces):
        for index, vertex in enumerate(face):
            previous = face[(index - 1) % len(face)]
            following = face[(index + 1) % len(face)]
            new_faces.append(
                (
                    old_vertex_indices[vertex],
                    edge_indices[tuple(sorted((vertex, following)))],
                    face_indices[face_index],
                    edge_indices[tuple(sorted((previous, vertex)))],
                )
            )
    return new_vertices, new_faces


def write_obj(path, vertices, faces):
    lines = ["o BrownBear_ForequarterSubdivisionCage"]
    lines.extend(f"v {x:.9f} {y:.9f} {z:.9f}" for x, y, z in vertices)
    lines.extend("f " + " ".join(str(index + 1) for index in face) for face in faces)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def render(path, vertices, faces, camera_location, target, scale, selector=None, wire=True):
    size = 1024
    camera = Vector(camera_location)
    forward = (Vector(target) - camera).normalized()
    right = forward.cross((0.0, 0.0, 1.0)).normalized()
    if right.length_squared < 0.5:
        right = Vector((1.0, 0.0, 0.0))
    up = right.cross(forward).normalized()

    projected = []
    depths = []
    for point in vertices:
        relative = Vector(point) - Vector(target)
        projected.append(
            (
                size * (0.5 + right.dot(relative) / scale),
                size * (0.5 - up.dot(relative) / scale),
            )
        )
        depths.append((Vector(point) - camera).dot(forward))

    image = Image.new("RGB", (size, size), (18, 22, 28))
    draw = ImageDraw.Draw(image)
    visible_faces = faces
    if selector is not None:
        visible_faces = [
            face
            for face in faces
            if selector(sum((Vector(vertices[index]) for index in face), start=Vector()) / len(face))
        ]
    ordered = sorted(visible_faces, key=lambda face: sum(depths[index] for index in face) / len(face), reverse=True)
    light = Vector((0.35, -0.55, 0.76)).normalized()
    for face in ordered:
        first, second, third = (Vector(vertices[index]) for index in face[:3])
        normal = (second - first).cross(third - first).normalized()
        brightness = 0.40 + 0.34 * abs(normal.dot(light))
        fill = tuple(int(value * brightness) for value in (94, 148, 179))
        polygon = [projected[index] for index in face]
        draw.polygon(polygon, fill=fill)
        if wire:
            draw.line(polygon + [polygon[0]], fill=(255, 113, 63), width=2, joint="curve")
    image.save(path)


def main():
    args = parse_args()
    root = Path(args.output_root)
    review = root / "review"
    review.mkdir(parents=True, exist_ok=True)
    module = load_builder(args.builder)
    vertices, faces, limbs = generate(module)
    metrics = topology(vertices, faces)
    write_obj(root / "brown_bear_forequarter_cage.obj", vertices, faces)
    views = (
        ("cage-side.png", (4.8, -0.05, 1.05), (0.0, -0.08, 0.92), 2.35, None),
        ("cage-front-three-quarter.png", (3.6, -4.5, 2.45), (0.0, -0.27, 0.90), 2.45, None),
        ("cage-ventral-three-quarter.png", (3.2, -4.1, -2.35), (0.0, -0.28, 0.72), 2.35, None),
        ("cage-top.png", (0.0, -0.10, 5.6), (0.0, -0.10, 0.82), 2.35, None),
        ("cage-paw-top.png", (0.66, -0.48, 4.7), (0.66, -0.48, 0.10), 0.72, lambda point: point.x > 0.45 and point.y < -0.22 and point.z < 0.32),
    )
    paths = []
    for filename, camera, target, scale, selector in views:
        output = review / filename
        render(output, vertices, faces, camera, target, scale, selector)
        paths.append(str(output))
    subdivided_vertices, subdivided_faces = vertices, faces
    for _ in range(2):
        subdivided_vertices, subdivided_faces = catmull_clark(subdivided_vertices, subdivided_faces)
    clay_views = (
        ("clay-side.png", (4.8, -0.05, 1.05), (0.0, -0.08, 0.92), 2.35, None),
        ("clay-front-three-quarter.png", (3.6, -4.5, 2.45), (0.0, -0.27, 0.90), 2.45, None),
        ("clay-ventral-three-quarter.png", (3.2, -4.1, -2.35), (0.0, -0.28, 0.72), 2.35, None),
        ("clay-paw-top.png", (0.66, -0.48, 4.7), (0.66, -0.48, 0.10), 0.72, lambda point: point.x > 0.45 and point.y < -0.22 and point.z < 0.32),
    )
    clay_paths = []
    for filename, camera, target, scale, selector in clay_views:
        output = review / filename
        render(output, subdivided_vertices, subdivided_faces, camera, target, scale, selector, wire=False)
        clay_paths.append(str(output))
    report = {
        "status": "standalone_geometry_preflight",
        "topology": metrics,
        "limbs": limbs,
        "reviewRenders": paths,
        "subdivision": {
            "algorithm": "Catmull-Clark",
            "levels": 2,
            "topology": topology(subdivided_vertices, subdivided_faces),
            "clayRenders": clay_paths,
        },
        "note": "Generated from the same builder functions; OBJ awaits Blender import while Metal startup is unavailable.",
    }
    (root / "standalone-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("BROWN_BEAR_CAGE_STANDALONE", json.dumps(report))


if __name__ == "__main__":
    main()
