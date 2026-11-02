import Foundation
import CoreGraphics
import Testing
@testable import Hypermeme

@Suite struct ImgflipParsing {
    @Test func readsTheAPI() throws {
        let json = #"{"success":true,"data":{"memes":[{"id":"181913649","name":"Drake Hotline Bling","url":"https://i.imgflip.com/30b1gx.jpg","width":1200,"height":1200,"box_count":2}]}}"#
        let templates = try Imgflip.parseAPI(Data(json.utf8))
        #expect(templates.first?.id == "30b1gx")
        #expect(templates.first?.boxCount == 2)
    }

    @Test func readsListingCardsAndSkipsAnimatedOnes() {
        let html = """
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
        let templates = Imgflip.parseListing(html)
        #expect(templates.count == 1)
        #expect(templates[0].id == "345v97")
        #expect(templates[0].name == "Woman Yelling & Cat")
        #expect(templates[0].slug == "Woman-Yelling-At-Cat")
    }

    private func generator(_ memes: String) -> String { "<script>usermemeID=0;memes=\(memes);other=1;</script>" }

    private let entry = ##"{"id":181913649,"name":"Drake","w":1200,"h":600,"file_type":"jpg","url_name":"Drake","altNames":"drakeposting","default_settings":"[{\"x\":600,\"y\":60,\"w\":300,\"h\":120,\"rotation\":349,\"font\":\"arial\",\"font_color\":\"#000000\",\"outline_color\":\"#ffffff\",\"force_caps\":false,\"text_align\":\"left\",\"vertical_align\":\"bottom\",\"font_max_size\":60},{\"type\":\"image\",\"x\":0,\"y\":0,\"w\":1,\"h\":1}]"}"##

    @Test func readsLayoutsAsFractionsOfTheImage() throws {
        let template = try #require(Imgflip.parseGenerator(generator("[\(entry)]")).first)
        // The URL key is the numeric id in base 36.
        #expect(template.id == "30b1gx")
        #expect(template.altNames == "drakeposting")
        let box = try #require(template.boxes?.first)
        #expect(template.boxes?.count == 1)
        #expect(box.x == 0.5)
        #expect(box.height == 0.2)
        #expect(box.rotation == 349)
        #expect(box.font == .arial)
        #expect(box.color == "#000000")
        #expect(!box.allCaps)
        #expect(box.align == .left)
        #expect(box.verticalAlign == .bottom)
        #expect(box.maxFontSize == 0.1)
    }

    @Test func readsTheObjectFormOfRareTemplatePages() {
        let templates = Imgflip.parseGenerator(generator(#"{"0":\#(entry),"X":{"id":61579,"name":"One Does Not Simply"}}"#))
        #expect(templates.count == 2)
        #expect(templates.contains { $0.id == "1bij" })
    }

    @Test func survivesPagesWithoutData() {
        #expect(Imgflip.parseGenerator("<html>nothing</html>").isEmpty)
        #expect(Imgflip.parseGenerator("memes=[{broken").isEmpty)
    }
}

@Suite struct Search {
    private let template = MemeTemplate(id: "a", name: "Drake Hotline Bling", altNames: "drakeposting, drake no yes")

    @Test func matchesEveryWordAcrossNames() {
        #expect(template.score(for: "hotline drake") != nil)
        #expect(template.score(for: "drakeposting") != nil)
        #expect(template.score(for: "drake cat") == nil)
        #expect(template.score(for: "   ") == nil)
    }

    @Test func prefersTheNameOverOtherNames() throws {
        let exact = try #require(template.score(for: "drake hotline bling"))
        let prefix = try #require(template.score(for: "drake"))
        let other = try #require(template.score(for: "drakeposting"))
        #expect(exact > prefix)
        #expect(prefix > other)
    }
}

@Suite struct CaptionStrip {
    @Test func keepsBoxesOverTheSamePartOfTheImageAndComesBack() {
        var document = MemeDocument(templateID: "a", boxes: [TextBox(text: "hi", x: 0.1, y: 0.5, width: 0.8, height: 0.25)])
        let original = document.boxes[0]
        document.setCaptionStrip(true)
        #expect(document.boxes.count == 2)
        #expect(document.boxes[0].y + document.boxes[0].height <= 1 / 1.28 * 0.28 + 0.001 + 0.2)
        document.setCaptionStrip(false)
        #expect(document.boxes.count == 1)
        #expect(document.captionStrip == 0)
        #expect(abs(document.boxes[0].y - original.y) < 0.0001)
        #expect(abs(document.boxes[0].height - original.height) < 0.0001)
    }
}

@Suite struct Rendering {
    private func blank(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func changedPixels(_ image: CGImage, inTop top: Bool) -> Int {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var count = 0
        // Bitmap contexts store the top row first.
        let rows = top ? 0 ..< image.height / 2 : image.height / 2 ..< image.height
        for row in rows {
            for column in 0 ..< image.width where abs(Int(pixels[(row * image.width + column) * 4]) - 128) > 40 {
                count += 1
            }
        }
        return count
    }

    @Test func smallTemplatesAreEnlargedForExport() throws {
        let document = MemeDocument(templateID: "a", boxes: [])
        let rendered = try #require(MemeRenderer.render(blank(width: 500, height: 250), document: document))
        #expect(rendered.width == 1000)
        #expect(rendered.height == 500)
    }

    @Test func theCaptionStripAddsHeight() throws {
        let document = MemeDocument(templateID: "a", boxes: [], captionStrip: 0.5)
        let rendered = try #require(MemeRenderer.render(blank(width: 1000, height: 400), document: document))
        #expect(rendered.height == 600)
    }

    @Test func textLandsInItsBox() throws {
        var box = TextBox.top()
        box.text = "Hello"
        let rendered = try #require(MemeRenderer.render(blank(width: 1000, height: 1000), document: MemeDocument(templateID: "a", boxes: [box])))
        #expect(changedPixels(rendered, inTop: true) > 1000)
        #expect(changedPixels(rendered, inTop: false) == 0)
    }

    @Test func longTextShrinksAndWordsStayWhole() {
        let room = CGSize(width: 400, height: 100)
        let short = MemeRenderer.fittedSize("HI", font: .impact, in: room, maximum: 300)
        let long = MemeRenderer.fittedSize(
            "ONE DOES NOT SIMPLY WRITE A VERY LONG CAPTION AND EXPECT IT TO FIT",
            font: .impact, in: room, maximum: 300
        )
        #expect(long < short)
        let word = MemeRenderer.fittedSize("SUPERCALIFRAGILISTIC", font: .impact, in: room, maximum: 300)
        #expect(word < 60)
    }
}
