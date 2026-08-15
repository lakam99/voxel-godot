import argparse
import hashlib
import html
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except ModuleNotFoundError as error:
    raise SystemExit(
        "Pillow is required. Run this script with the bundled Codex workspace "
        "Python reported by codex_app__load_workspace_dependencies."
    ) from error


COMMONS_FILES = [
    {"title": "File:Bear paw.jpg", "regions": ["feet"], "notes": "Plantar pad and digit arrangement."},
    {"title": "File:Brown Bear Paws.jpg", "regions": ["feet", "forelegs"], "notes": "Weight-bearing forepaw and claw emergence."},
    {"title": "File:Wiesbaden-Fasanerie vordere Bärentatze.jpg", "regions": ["feet", "forelegs"], "notes": "Close forepaw proportions."},
    {"title": "File:2016-09 zoo sauvage de Saint-Félicien - Ursus arctos 04.jpg", "regions": ["feet", "forelegs"], "notes": "Live brown-bear paw context."},
    {"title": "File:Brown bear close up head ursus arctos.jpg", "regions": ["face"], "notes": "Front facial planes and muzzle width."},
    {"title": "File:Kodiak brown bear FWS 18390.jpg", "regions": ["face", "shoulders"], "notes": "Kodiak head, ruff, and shoulder relationship."},
    {"title": "File:Ursus arctos closeup, looking up and toward the right.jpg", "regions": ["face"], "notes": "Three-quarter muzzle, brow, cheek, and ear roots."},
    {"title": "File:Ursus arctos skull.JPG", "regions": ["face", "skeleton"], "notes": "Brown-bear skull authority."},
    {"title": "File:Ursus arctos 14zz.jpg", "regions": ["skeleton", "back", "legs"], "notes": "Brown-bear skeletal structure."},
    {"title": "File:Ursus middendorffi 0zz.jpg", "regions": ["skeleton", "face"], "notes": "Kodiak skull and skeletal comparison."},
    {"title": "File:Ursus middendorffi 2zz.jpg", "regions": ["feet", "forelegs", "skeleton"], "notes": "Kodiak forepaw skeleton and digit articulation."},
    {
        "title": "File:Description iconographique comparée du squelette et du système dentaire des mammifères récents et fossiles (Ursus arctos californicus).jpg",
        "regions": ["skeleton", "shoulders", "forelegs", "legs", "back"],
        "notes": "Side-view California grizzly skeleton for scapula, elbow, wrist, pelvis, and load-line landmarks.",
    },
    {"title": "File:Ursus arctos by OpenCage.jpg", "regions": ["skeleton", "shoulders", "forelegs", "legs"], "notes": "Mounted brown-bear skeleton with readable appendicular proportions."},
    {"title": "File:Grizzy Bear Skeleton.jpg", "regions": ["skeleton", "shoulders", "forelegs", "back"], "notes": "Grizzly skeleton reference emphasizing shoulder girdle and thoracic relationship."},
    {"title": "File:Ursus arctos - Norway.jpg", "regions": ["back", "rear", "legs"], "notes": "Rear and topline mass."},
    {"title": "File:Brown bear in Izembek Lagoon (12993022915).jpg", "regions": ["whole", "shoulders", "forelegs", "feet", "back", "rear", "legs"], "notes": "Side-on walking adult with weight-bearing limb relationships."},
    {"title": "File:Brown bear strolling at rivers edge.jpg", "regions": ["whole", "shoulders", "forelegs", "feet", "back", "rear", "legs"], "notes": "Side-profile gait and forepaw placement reference."},
    {"title": "File:Brown Bear Standing (54308774914).jpg", "regions": ["shoulders", "forelegs", "face"], "notes": "Upright shoulder, chest, forelimb, and head relationship."},
    {"title": "File:Eurasian brown bear (Ursus arctos arctos) standing on rear legs, Skansen, Stockholm, Sweden julesvernex2.jpg", "regions": ["shoulders", "forelegs", "rear", "face"], "notes": "Standing anatomy and hanging forelimb mass."},
]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("assets/art-source/brown_bear_poc/reference-library"))
    parser.add_argument("--user-reference", action="append", type=Path, default=[])
    return parser.parse_args()


def slug(title):
    value = title.removeprefix("File:").rsplit(".", 1)[0].lower()
    return re.sub(r"[^a-z0-9]+", "-", value).strip("-")


def metadata_text(value):
    return re.sub(r"<[^>]+>", "", html.unescape(value or "")).strip()


def commons_records():
    titles = "|".join(item["title"] for item in COMMONS_FILES)
    params = {
        "action": "query",
        "titles": titles,
        "prop": "imageinfo",
        "iiprop": "url|mime|size|extmetadata",
        "iiurlwidth": 1600,
        "format": "json",
        "formatversion": 2,
    }
    url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": "CodexBearReferenceBuilder/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
    pages = {page["title"]: page for page in payload.get("query", {}).get("pages", [])}
    result = []
    for item in COMMONS_FILES:
        page = pages.get(item["title"])
        if not page or not page.get("imageinfo"):
            continue
        info = page["imageinfo"][0]
        metadata = info.get("extmetadata", {})
        result.append(
            {
                **item,
                "pageUrl": info.get("descriptionurl"),
                "downloadUrl": info.get("thumburl") or info.get("url"),
                "originalUrl": info.get("url"),
                "license": metadata_text(metadata.get("LicenseShortName", {}).get("value")),
                "licenseUrl": metadata.get("LicenseUrl", {}).get("value", ""),
                "artist": metadata_text(metadata.get("Artist", {}).get("value")),
                "description": metadata_text(metadata.get("ImageDescription", {}).get("value")),
            }
        )
    return result


def normalized_image(source, destination):
    with Image.open(source) as image:
        image = ImageOps.exif_transpose(image).convert("RGB")
        image.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
        image.save(destination, "JPEG", quality=85, optimize=True, progressive=True)


def download_record(record, images_dir):
    output = images_dir / (slug(record["title"]) + ".jpg")
    if output.exists():
        return output
    raw_path = images_dir / (slug(record["title"]) + ".download")
    request = urllib.request.Request(record["downloadUrl"], headers={"User-Agent": "CodexBearReferenceBuilder/1.0"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                raw_path.write_bytes(response.read())
            break
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 5:
                raise
            time.sleep(max(float(error.headers.get("Retry-After", 0) or 0), 2.0 ** attempt))
    time.sleep(0.75)
    normalized_image(raw_path, output)
    raw_path.unlink()
    return output


def make_contact_sheet(region, records, destination):
    tile_width, tile_height = 640, 500
    columns = 2
    rows = (len(records) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * tile_width, rows * tile_height), (28, 28, 30))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=18)
    for index, record in enumerate(records):
        x = (index % columns) * tile_width
        y = (index // columns) * tile_height
        with Image.open(record["path"]) as image:
            image = ImageOps.contain(image.convert("RGB"), (tile_width - 24, tile_height - 70))
            sheet.paste(image, (x + (tile_width - image.width) // 2, y + 8))
        label = f"{index + 1}. {record['title'].removeprefix('File:')}"
        draw.text((x + 12, y + tile_height - 52), label[:70], fill=(238, 238, 238), font=font)
    sheet.save(destination / f"{region}.webp", "WEBP", quality=82, method=6)


def main():
    args = parse_args()
    output = args.output.resolve()
    images_dir = output / "images"
    sheets_dir = output / "contact-sheets"
    images_dir.mkdir(parents=True, exist_ok=True)
    sheets_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    seen_hashes = {}
    for record in commons_records():
        path = download_record(record, images_dir)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest in seen_hashes:
            path.unlink()
            continue
        seen_hashes[digest] = str(path)
        manifest.append({**record, "path": str(path), "sha256": digest, "bytes": path.stat().st_size})
    for index, source in enumerate(args.user_reference, start=1):
        if not source.exists():
            continue
        path = images_dir / f"user-reference-{index:02d}.jpg"
        normalized_image(source, path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest in seen_hashes:
            path.unlink()
            continue
        seen_hashes[digest] = str(path)
        manifest.append(
            {
                "title": f"User reference {index}",
                "regions": ["whole", "face", "shoulders", "forelegs", "feet", "back", "rear", "legs"],
                "notes": "User-supplied primary visual target.",
                "pageUrl": "user-supplied",
                "downloadUrl": "user-supplied",
                "originalUrl": "user-supplied",
                "license": "reference-only",
                "licenseUrl": "",
                "artist": "unknown",
                "description": "User-supplied brown-bear reference.",
                "path": str(path),
                "sha256": digest,
                "bytes": path.stat().st_size,
            }
        )
    regions = sorted({region for record in manifest for region in record["regions"]})
    for region in regions:
        selected = [record for record in manifest if region in record["regions"]]
        make_contact_sheet(region, selected, sheets_dir)
    report = {
        "policy": "Curated 1600px JPEG references plus compact regional WebP contact sheets; source and license metadata retained.",
        "records": manifest,
        "regions": {region: sum(region in record["regions"] for record in manifest) for region in regions},
        "totalImageBytes": sum(record["bytes"] for record in manifest),
    }
    (output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"records": len(manifest), "regions": report["regions"], "totalImageBytes": report["totalImageBytes"]}, indent=2))


if __name__ == "__main__":
    main()
