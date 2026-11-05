import Foundation
import AVFoundation
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

@Suite struct PasteTarget {
    @Test func pastesIntoTextAndIntoAppsThatDoNotReportFocus() {
        #expect(Inserter.canTakePaste(role: "AXTextArea"))
        #expect(Inserter.canTakePaste(role: "AXTextField"))
        #expect(Inserter.canTakePaste(role: nil))
        #expect(Inserter.canTakePaste(role: "AXWebArea"))
    }

    @Test func waitsWhenNothingFocusedCanTakeIt() {
        #expect(!Inserter.canTakePaste(role: "AXWindow"))
        #expect(!Inserter.canTakePaste(role: "AXOutline"))
    }
}

@Suite struct Downloads {
    @Test func neverReplacesAFileAndCleansTheName() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = Inserter.freeFile(for: "a/b: c", in: folder)
        #expect(first.lastPathComponent == "a-b- c.png")
        try Data().write(to: first)
        #expect(Inserter.freeFile(for: "a/b: c", in: folder).lastPathComponent == "a-b- c 2.png")
        #expect(Inserter.freeFile(for: " .. ", in: folder).lastPathComponent == "Meme.png")
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

@Suite struct CommunityTemplates {
    private let index = #"""
    {"version":1,"templates":[{"id":"paris-cafe-riot","name":"Parisian Café During a Riot",
     "aliases":["woman drinking coffee during riot"],"description":"A woman sips an espresso while riot police line up.",
     "usage":"Staying calm while everything falls apart.","tags":["calm","paris"],"image":"image.jpg","width":720,"height":405,
     "captionStrip":true,"boxes":[],"source":{"url":"https://x.com/a/status/1"},
     "imageURL":"https://raw.githubusercontent.com/alexisbcz/hypermeme-templates/main/templates/paris-cafe-riot/image.jpg"},
     {"id":"boxed","name":"Boxed","aliases":[],"description":"d","usage":"u","tags":[],"image":"image.png","width":10,"height":10,
     "captionStrip":false,"boxes":[{"x":0.1,"y":0.2,"width":0.5,"height":0.3,"font":"arial","allCaps":false}],"source":{"url":"u"},
     "imageURL":"https://example.com/boxed/image.png"}]}
    """#

    @Test func readsTheIndexAndDownloadsFromIt() throws {
        let templates = try Community.parse(Data(index.utf8))
        let cafe = try #require(templates.first)
        #expect(cafe.id == "community-paris-cafe-riot")
        #expect(cafe.imageURL?.lastPathComponent == "image.jpg")
        #expect(cafe.thumbnailURL == cafe.imageURL)
        #expect(templates[1].fileType == "png")
        #expect(templates[1].boxes?.first?.font == .arial)
        #expect(templates[1].boxes?.first?.allCaps == false)
    }

    @Test func isFoundByWhatItMeans() throws {
        let cafe = try #require(Community.parse(Data(index.utf8)).first)
        #expect(cafe.score(for: "coffee riot") != nil)
        #expect(cafe.score(for: "calm espresso") != nil)
        #expect(cafe.score(for: "drake") == nil)
    }

    @Test func opensWithACaptionStripAndNothingElse() throws {
        let cafe = try #require(Community.parse(Data(index.utf8)).first)
        let document = cafe.startingDocument
        #expect(document.captionStrip > 0)
        #expect(document.boxes.count == 1)
        #expect(MemeTemplate(id: "a", name: "A").startingDocument.boxes.count == 2)
    }

    @Test func templatesSavedBeforeStillLoad() throws {
        let saved = #"{"id":"30b1gx","name":"Drake","fileType":"jpg","boxCount":2,"altNames":""}"#
        let template = try JSONDecoder().decode(MemeTemplate.self, from: Data(saved.utf8))
        #expect(template.sourceImageURL == nil)
        #expect(template.imageURL?.absoluteString == "https://i.imgflip.com/30b1gx.jpg")
    }
}

@Suite struct VideoMemes {
    private let index = #"""
    {"version":1,"templates":[{"id":"terry-davis-suck-it-up","name":"Terry Davis: Suck It Up","aliases":["suck it up","terry davis"],
     "description":"Terry Davis in sunglasses on a street.","usage":"Tough love.","tags":["templeos","video"],"image":"image.jpg",
     "width":720,"height":406,"video":"video.mp4","duration":13.4,"captionStrip":true,"boxes":[],"source":{"url":"u"},
     "imageURL":"https://example.com/t/image.jpg","videoURL":"https://example.com/t/video.mp4"}]}
    """#

    @Test func readsTheVideoAndKeepsItsPosterForSearch() throws {
        let template = try #require(Community.parse(Data(index.utf8)).first)
        #expect(template.isVideo)
        #expect(template.duration == 13.4)
        #expect(template.videoURL?.lastPathComponent == "video.mp4")
        #expect(template.thumbnailURL?.lastPathComponent == "image.jpg")
        #expect(template.score(for: "terry davis video") != nil)
        #expect(template.score(for: "templeos suck") != nil)
    }

    @Test func memesSavedBeforeVideosStillLoad() throws {
        let saved = #"{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","name":"Drake","document":{"templateID":"a","boxes":[],"captionStrip":0},"created":0}"#
        let meme = try JSONDecoder().decode(SavedMeme.self, from: Data(saved.utf8))
        #expect(meme.isVideo == nil)
    }

    @Test func captionsAreClearExceptTheStripAndText() throws {
        var document = MemeTemplate(id: "a", name: "A", captionStrip: true).startingDocument
        document.boxes[0].text = "When the build passes"
        let overlay = try #require(MemeRenderer.captions(document, size: CGSize(width: 400, height: 200)))
        #expect(overlay.width == 400)
        #expect(overlay.height == 256)
        let pixels = try rgba(overlay)
        #expect(alpha(pixels, overlay, x: 200, y: 250) == 0) // over the picture
        #expect(alpha(pixels, overlay, x: 2, y: 2) == 255) // the strip
    }

    @Test func exportsCaptionsOnEveryFrameWithTheStripAbove() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "gray.mp4")
        try await writeGrayVideo(to: source, size: CGSize(width: 320, height: 240))

        var document = MemeTemplate(id: "a", name: "A", captionStrip: true).startingDocument
        document.boxes[0].text = "Suck it up"
        let output = folder.appending(path: "meme.mp4")
        try await VideoExporter.export(source, document: document, to: output)

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 320)
        #expect(size.height == 306) // 240 * 1.28, rounded down to even

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 1, timescale: 2)).image
        let pixels = try rgba(frame)
        #expect(red(pixels, frame, x: 316, y: 4) > 230) // the strip is white
        #expect(abs(Int(red(pixels, frame, x: 160, y: 200)) - 128) < 20) // the video is below it
    }

    @Test func withoutCaptionsTheVideoIsUntouched() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "gray.mp4")
        try await writeGrayVideo(to: source, size: CGSize(width: 64, height: 64))
        let output = folder.appending(path: "meme.mp4")
        try await VideoExporter.export(source, document: MemeDocument(templateID: "a", boxes: []), to: output)
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
    }

    // MARK: Helpers

    /// Top row first.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func alpha(_ pixels: [UInt8], _ image: CGImage, x: Int, y: Int) -> UInt8 { pixels[(y * image.width + x) * 4 + 3] }
    private func red(_ pixels: [UInt8], _ image: CGImage, x: Int, y: Int) -> UInt8 { pixels[(y * image.width + x) * 4] }

    /// One second of mid-gray frames.
    private func writeGrayVideo(to url: URL, size: CGSize) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< 10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
