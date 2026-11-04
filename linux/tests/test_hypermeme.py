"""Tests for Hypermeme on Linux. They run offline: `make -C linux test`."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import cairo

from hypermeme import app, imgflip, renderer, theme
from hypermeme.library import Library, free_file
from hypermeme.models import MemeDocument, MemeTemplate, SavedMeme, TextBox


def generator(memes: str) -> str:
    return f"<script>usermemeID=0;memes={memes};other=1;</script>"


ENTRY = json.dumps(
    {
        "id": 181913649,
        "name": "Drake",
        "w": 1200,
        "h": 600,
        "file_type": "jpg",
        "url_name": "Drake",
        "altNames": "drakeposting",
        "default_settings": json.dumps(
            [
                {
                    "x": 600, "y": 60, "w": 300, "h": 120, "rotation": 349, "font": "arial",
                    "font_color": "#000000", "outline_color": "#ffffff", "force_caps": False,
                    "text_align": "left", "vertical_align": "bottom", "font_max_size": 60,
                },
                {"type": "image", "x": 0, "y": 0, "w": 1, "h": 1},
            ]
        ),
    }
)


class ImgflipParsing(unittest.TestCase):
    def test_reads_the_api(self):
        data = b'{"success":true,"data":{"memes":[{"id":"181913649","name":"Drake Hotline Bling","url":"https://i.imgflip.com/30b1gx.jpg","width":1200,"height":1200,"box_count":2}]}}'
        templates = imgflip.parse_api(data)
        self.assertEqual(templates[0].id, "30b1gx")
        self.assertEqual(templates[0].boxCount, 2)
        self.assertEqual(templates[0].fileType, "jpg")

    def test_reads_listing_cards_and_skips_animated_ones(self):
        html = """
        <div class="mt-box">
            <h3 class="mt-title">
                <a title="Woman Yelling At Cat Meme" href="/meme/Woman-Yelling-At-Cat">Woman Yelling &amp; Cat</a>
            </h3>
            <img class="shadow" src="//i.imgflip.com/4/345v97.jpg"/>
            <a class="mt-caption l but" href="/memegenerator/Woman-Yelling-At-Cat">Add Caption</a>
        </div><div class="mt-box">
            <h3 class="mt-title"><a href="/meme/Some-Gif">Some Gif</a></h3>
            <img class="shadow" src="//i.imgflip.com/2/abc.jpg"/>
            <a class="mt-caption l but" href="/gif-maker?template=1">Add Caption</a>
        </div>
        """
        templates = imgflip.parse_listing(html)
        self.assertEqual(len(templates), 1)
        self.assertEqual(templates[0].id, "345v97")
        self.assertEqual(templates[0].name, "Woman Yelling & Cat")
        self.assertEqual(templates[0].slug, "Woman-Yelling-At-Cat")

    def test_reads_layouts_as_fractions_of_the_image(self):
        template = imgflip.parse_generator(generator(f"[{ENTRY}]"))[0]
        # The URL key is the numeric id in base 36.
        self.assertEqual(template.id, "30b1gx")
        self.assertEqual(template.altNames, "drakeposting")
        self.assertEqual(len(template.boxes), 1)
        box = template.boxes[0]
        self.assertEqual(box.x, 0.5)
        self.assertEqual(box.height, 0.2)
        self.assertEqual(box.rotation, 349)
        self.assertEqual(box.font, "arial")
        self.assertEqual(box.color, "#000000")
        self.assertEqual(box.outline, "#FFFFFF")
        self.assertFalse(box.allCaps)
        self.assertEqual(box.align, "left")
        self.assertEqual(box.verticalAlign, "bottom")
        self.assertAlmostEqual(box.maxFontSize, 0.1)

    def test_reads_the_object_form_of_rare_template_pages(self):
        templates = imgflip.parse_generator(generator('{"0":%s,"X":{"id":61579,"name":"One Does Not Simply"}}' % ENTRY))
        self.assertEqual(len(templates), 2)
        self.assertIn("1bij", [t.id for t in templates])

    def test_survives_pages_without_data(self):
        self.assertEqual(imgflip.parse_generator("<html>nothing</html>"), [])
        self.assertEqual(imgflip.parse_generator("memes=[{broken"), [])
        self.assertIsNone(imgflip.balanced_json('{"a": "}"'))
        self.assertEqual(imgflip.balanced_json('{"a": "}"} trailing'), '{"a": "}"}')

    def test_maps_imgflip_fonts(self):
        from hypermeme.models import font_from_imgflip

        self.assertEqual(font_from_imgflip(None), "impact")
        self.assertEqual(font_from_imgflip("Comic Sans MS"), "comic")
        self.assertEqual(font_from_imgflip("something"), "arial")


class Search(unittest.TestCase):
    template = MemeTemplate(id="a", name="Drake Hotline Bling", altNames="drakeposting, drake no yes")

    def test_matches_every_word_across_names(self):
        self.assertIsNotNone(self.template.score("hotline drake"))
        self.assertIsNotNone(self.template.score("drakeposting"))
        self.assertIsNone(self.template.score("drake cat"))
        self.assertIsNone(self.template.score("   "))

    def test_prefers_the_name_over_other_names(self):
        exact = self.template.score("drake hotline bling")
        prefix = self.template.score("drake")
        other = self.template.score("drakeposting")
        self.assertGreater(exact, prefix)
        self.assertGreater(prefix, other)


class CaptionStrip(unittest.TestCase):
    def test_keeps_boxes_over_the_same_part_of_the_image_and_comes_back(self):
        document = MemeDocument("a", [TextBox(text="hi", x=0.1, y=0.5, width=0.8, height=0.25)])
        original = document.boxes[0].copy()
        document.set_caption_strip(True)
        self.assertEqual(len(document.boxes), 2)
        self.assertLessEqual(document.boxes[0].y + document.boxes[0].height, 1 / 1.28 * 0.28 + 0.001 + 0.2)
        document.set_caption_strip(False)
        self.assertEqual(len(document.boxes), 1)
        self.assertEqual(document.captionStrip, 0)
        self.assertAlmostEqual(document.boxes[0].y, original.y, places=4)
        self.assertAlmostEqual(document.boxes[0].height, original.height, places=4)

    def test_round_trips_through_json(self):
        document = MemeDocument("a", TextBox.defaults(3))
        document.boxes[1].text = "middle"
        meme = SavedMeme("Name", document)
        again = SavedMeme.from_json(json.loads(json.dumps(meme.to_json())))
        self.assertEqual(again, meme)
        self.assertEqual(again.title, "middle")


def blank(width: int, height: int) -> cairo.ImageSurface:
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    ctx = cairo.Context(surface)
    ctx.set_source_rgb(0.5, 0.5, 0.5)
    ctx.paint()
    return surface


def changed_pixels(surface: cairo.ImageSurface, top: bool) -> int:
    surface.flush()
    data, stride = surface.get_data(), surface.get_stride()
    height, width = surface.get_height(), surface.get_width()
    rows = range(0, height // 2) if top else range(height // 2, height)
    count = 0
    for row in rows:
        line = data[row * stride: row * stride + width * 4]
        # ARGB32 is BGRA in memory on little-endian machines; any channel will do on gray.
        count += sum(1 for column in range(0, width * 4, 4) if abs(line[column] - 128) > 40)
    return count


class Rendering(unittest.TestCase):
    def test_small_templates_are_enlarged_for_export(self):
        rendered = renderer.render(blank(500, 250), MemeDocument("a", []))
        self.assertEqual((rendered.get_width(), rendered.get_height()), (1000, 500))

    def test_the_caption_strip_adds_height(self):
        rendered = renderer.render(blank(1000, 400), MemeDocument("a", [], captionStrip=0.5))
        self.assertEqual(rendered.get_height(), 600)

    def test_text_lands_in_its_box(self):
        box = TextBox.top()
        box.text = "Hello"
        rendered = renderer.render(blank(400, 400), MemeDocument("a", [box]))
        self.assertGreater(changed_pixels(rendered, top=True), 1000)
        self.assertEqual(changed_pixels(rendered, top=False), 0)

    def test_long_text_shrinks_and_words_stay_whole(self):
        short = renderer.fitted_size("HI", "impact", 400, 100, 300)
        long = renderer.fitted_size("ONE DOES NOT SIMPLY WRITE A VERY LONG CAPTION AND EXPECT IT TO FIT", "impact", 400, 100, 300)
        self.assertLess(long, short)
        self.assertLess(renderer.fitted_size("SUPERCALIFRAGILISTIC", "impact", 400, 100, 300), 60)

    def test_bundled_fonts_are_used(self):
        from gi.repository import PangoCairo

        renderer.register_fonts()
        families = {f.get_name() for f in PangoCairo.FontMap.get_default().list_families()}
        self.assertTrue({"Anton", "Comic Neue", "Permanent Marker"} <= families)

    def test_fonts_reach_worker_threads(self):
        import threading

        sizes = {}
        sizes["main"] = renderer.fitted_size("MEME", "impact", 400, 100, 300)
        worker = threading.Thread(target=lambda: sizes.update(worker=renderer.fitted_size("MEME", "impact", 400, 100, 300)))
        worker.start()
        worker.join()
        self.assertEqual(sizes["main"], sizes["worker"])


class LibraryStorage(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.folder)

    def write_image(self, name="photo.png", size=(300, 200)) -> Path:
        path = self.folder / name
        blank(*size).write_to_png(str(path))
        return path

    def test_uploads_memes_and_favorites_persist(self):
        library = Library(self.folder / "data")
        template = library.add_upload(self.write_image())
        self.assertTrue(template.is_upload)
        self.assertEqual(template.name, "photo")
        library.toggle_favorite(template)
        image = renderer.load_image(library.template_file(template))
        document = MemeDocument(template.id, template.starting_boxes())
        document.boxes[0].text = "caption"
        meme = library.save_meme(document, image, template)
        self.assertTrue(library.file(meme).exists())
        # Saving the same meme again gives back the first copy.
        self.assertEqual(library.save_meme(document.copy(), image, template).id, meme.id)

        again = Library(self.folder / "data")
        self.assertEqual([t.id for t in again.uploads], [template.id])
        self.assertEqual(again.favorites, [template.id])
        self.assertEqual(again.recents, [template.id])
        self.assertEqual([m.id for m in again.memes], [meme.id])
        self.assertEqual(again.memes[0].caption, "caption")

        again.delete_upload(template)
        self.assertEqual(again.favorite_templates(), [])
        self.assertFalse(again.template_file(template).exists())

    def test_huge_photos_are_scaled_down(self):
        library = Library(self.folder / "data")
        template = library.add_upload(self.write_image("big.png", (4800, 1200)))
        image = renderer.load_image(library.template_file(template))
        self.assertEqual((image.get_width(), image.get_height()), (2400, 600))

    def test_rejects_files_that_are_not_images(self):
        library = Library(self.folder / "data")
        junk = self.folder / "notes.txt"
        junk.write_text("hello")
        self.assertIsNone(library.add_upload(junk))

    def test_local_matches_rank_and_merge_known_layouts(self):
        library = Library(self.folder / "data")
        drake = imgflip.parse_generator(generator(f"[{ENTRY}]"))[0]
        library.known[drake.id] = drake
        library.popular = [library.merged(MemeTemplate(id="30b1gx", name="Drake")), MemeTemplate(id="b", name="Two Buttons")]
        self.assertEqual(library.local_matches("drakeposting")[0].id, "30b1gx")
        self.assertIsNotNone(library.merged(MemeTemplate(id="30b1gx", name="Drake")).boxes)

    def test_never_replaces_a_download_and_cleans_the_name(self):
        first = free_file("a/b: c", self.folder)
        self.assertEqual(first.name, "a-b- c.png")
        first.write_bytes(b"")
        self.assertEqual(free_file("a/b: c", self.folder).name, "a-b- c 2.png")
        self.assertEqual(free_file(" .. ", self.folder).name, "Meme.png")


class Commands(unittest.TestCase):
    def test_reads_links(self):
        self.assertEqual(app.parse(["hypermeme://panel?q=drake"]), ("panel", {"query": "drake"}))
        self.assertEqual(app.parse(["hypermeme://search?q=boat%20cat"]), ("search", {"query": "boat cat"}))
        action, options = app.parse(["hypermeme://edit?template=two%20buttons&text=ship%20it&text=write%20tests&panel=1"])
        self.assertEqual(action, "edit")
        self.assertEqual(options, {"template": "two buttons", "texts": ["ship it", "write tests"], "panel": True})

    def test_reads_arguments(self):
        self.assertEqual(app.parse([]), ("window", {}))
        self.assertEqual(app.parse(["toggle"]), ("toggle", {"query": None}))
        self.assertEqual(app.parse(["panel", "boat", "cat"]), ("panel", {"query": "boat cat"}))
        self.assertEqual(app.parse(["edit", "drake", "a", "b", "--panel"])[1], {"template": "drake", "texts": ["a", "b"], "panel": True})
        self.assertEqual(app.parse(["--background"]), ("background", {}))
        self.assertEqual(app.parse(["nonsense"]), ("help", {}))


class OmarchyTheme(unittest.TestCase):
    def test_turns_colors_into_libadwaita_palette(self):
        folder = Path(tempfile.mkdtemp())
        try:
            colors = folder / "colors.toml"
            colors.write_text('mode = "dark"\naccent = "#78824b"\nbackground = "#222222"\nforeground = "#c2c2b0"\n')
            css = theme.palette_css(theme.read_colors(colors))
            self.assertIn("@define-color accent_bg_color #78824b;", css)
            self.assertIn("@define-color window_bg_color #222222;", css)
            self.assertEqual(theme.palette_css({}), "")
            self.assertEqual(theme.read_colors(folder / "missing.toml"), {})
        finally:
            shutil.rmtree(folder)


if __name__ == "__main__":
    unittest.main()
