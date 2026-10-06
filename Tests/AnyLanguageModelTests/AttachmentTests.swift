import Foundation
import Testing

@_spi(Compatibility) @testable import AnyLanguageModel

#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import ImageIO
#endif
#if canImport(FoundationModels) && compiler(>=6.4) && !os(tvOS) && !os(watchOS)
    import FoundationModels
#endif

@Suite("Prompt attachments")
struct AttachmentTests {
    private let imageURL = URL(fileURLWithPath: "/tmp/attachment-fixture.png")

    private func prompt() -> AnyLanguageModel.Prompt {
        AnyLanguageModel.Prompt {
            "before"
            AnyLanguageModel.Attachment(imageURL: imageURL)
            "after"
        }
    }

    @Test func buildersAndRepresentablesPreserveOrderedImages() throws {
        let original = prompt()
        struct Representable: AnyLanguageModel.PromptRepresentable {
            let promptRepresentation: AnyLanguageModel.Prompt
        }
        let wrapped = AnyLanguageModel.Prompt(Representable(promptRepresentation: original))
        let composed = AnyLanguageModel.Prompt {
            if true { wrapped }
            for item in [original] { item }
        }
        let expected = try original.makeTranscriptSegments()
        #expect(try wrapped.makeTranscriptSegments() == expected)
        let combined = try composed.makeTranscriptSegments()
        #expect(combined.count == 5)
        let sources: [AnyLanguageModel.Transcript.ImageSegment.Source] = combined.compactMap {
            if case .image(let value) = $0 { return value.source }
            return nil
        }
        let texts: [String] = combined.compactMap {
            if case .text(let value) = $0 { return value.content }
            return nil
        }
        #expect(sources == [.url(imageURL), .url(imageURL)])
        #expect(texts == ["before", "after\nbefore", "after"])
        #expect(original.description == "before\n<image>\nafter")
        #expect(try AnyLanguageModel.Prompt([original, original]).makeTranscriptSegments() == combined)
    }

    @Test func ordinaryToolReturnsImagesAndTranscriptRoundTrips() async throws {
        let segments = try await ImageTool(output: prompt()).makeOutputSegments(
            from: AnyLanguageModel.GeneratedContent("read")
        )
        #expect(segments.count == 3)
        guard case .text(let before) = segments[0], case .image(let image) = segments[1],
            case .text(let after) = segments[2]
        else { Issue.record("Tool output lost its ordered image"); return }
        #expect(before.content == "before")
        #expect(after.content == "after")
        #expect(image.source == .url(imageURL))
        let transcript = AnyLanguageModel.Transcript(entries: [
            .toolOutput(.init(id: "call", toolName: "image", segments: segments))
        ])
        #expect(
            try JSONDecoder().decode(AnyLanguageModel.Transcript.self, from: JSONEncoder().encode(transcript))
                == transcript
        )
    }

    @Test func directSessionPromptsRetainImagesInBothModes() async throws {
        for streaming in [false, true] {
            let session = AnyLanguageModel.LanguageModelSession(model: MockLanguageModel())
            let input = prompt()
            if streaming {
                _ = try await session.streamResponse(to: input).collect()
            } else {
                _ = try await session.respond(to: input)
            }
            let first = try #require(session.transcript.first)
            guard case .prompt(let recorded) = first else { Issue.record("Missing prompt"); return }
            #expect(recorded.segments == (try input.makeTranscriptSegments()))
        }
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
        private func image() throws -> CGImage {
            let context = try #require(
                CGContext(
                    data: nil,
                    width: 2,
                    height: 3,
                    bitsPerComponent: 8,
                    bytesPerRow: 8,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            return try #require(context.makeImage())
        }

        @Test func imageEncodingRetainsPixelsAndOrientation() async throws {
            let value = try image()
            let input = AnyLanguageModel.Prompt {
                "image note"
                AnyLanguageModel.Attachment(value, orientation: .right)
            }
            let segments = try await ImageTool(output: input).makeOutputSegments(
                from: AnyLanguageModel.GeneratedContent("read")
            )
            guard case .image(let segment) = segments.last, case .data(let bytes, let mime) = segment.source else {
                Issue.record("No encoded image"); return
            }
            #expect(mime == "image/png")
            let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == value.width)
            #expect(decoded.height == value.height)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(
                (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
                    == CGImagePropertyOrientation.right.rawValue
            )
            #if canImport(FoundationModels) && compiler(>=6.4) && !os(tvOS) && !os(watchOS)
                if #available(macOS 27, iOS 27, visionOS 27, *) {
                    let native = segments.toFoundationModels()
                    guard case .attachment(let attachment) = native.last,
                        case .image(let restoredImage) = attachment.content
                    else {
                        Issue.record("Encoded attachment lost in native transcript bridge"); return
                    }
                    #expect(restoredImage.orientation == .right)
                }
            #endif
            let transcript = AnyLanguageModel.Transcript(entries: [
                .toolOutput(.init(id: "image-call", toolName: "image", segments: segments))
            ])
            #expect(
                try JSONDecoder().decode(AnyLanguageModel.Transcript.self, from: JSONEncoder().encode(transcript))
                    == transcript
            )
        }
    #endif

    #if canImport(FoundationModels) && compiler(>=6.4) && !os(tvOS) && !os(watchOS)
        @available(macOS 27, iOS 27, visionOS 27, *)
        @Test func nativeBridgeRetainsAttachment() async throws {
            let input = try AnyLanguageModel.Prompt {
                "before"
                AnyLanguageModel.Attachment(try image(), orientation: .right)
                "after"
            }
            let session = FoundationModels.LanguageModelSession(model: BridgeModel())
            _ = try await session.respond(to: input.toFoundationModels())
            guard case .prompt(let recorded) = try #require(session.transcript.first) else {
                Issue.record("Missing native prompt"); return
            }
            #expect(recorded.segments.count == 3)
            guard case .attachment(let segment) = recorded.segments[1], case .image(let image) = segment.content else {
                Issue.record("Native bridge lost attachment"); return
            }
            #expect(image.orientation == .right)
        }
        @available(macOS 27, iOS 27, visionOS 27, *)
        @Test func nativeToolWrapperRetainsOrdinaryImageOutput() async throws {
            let input = try AnyLanguageModel.Prompt {
                "tool note"
                AnyLanguageModel.Attachment(try image(), orientation: .right)
            }
            let tools: [any AnyLanguageModel.Tool] = [ImageTool(output: input)]
            let session = FoundationModels.LanguageModelSession(
                model: BridgeModel(callsTools: true),
                tools: tools.toFoundationModels()
            )
            _ = try await session.respond(to: "read image")
            let output = try #require(
                session.transcript.compactMap { entry -> FoundationModels.Transcript.ToolOutput? in
                    if case .toolOutput(let output) = entry { return output }
                    return nil
                }.first
            )
            #expect(output.id == "image-call")
            #expect(output.segments.count == 2)
            guard case .attachment(let segment) = output.segments[1], case .image(let image) = segment.content else {
                Issue.record("Native Tool wrapper flattened image"); return
            }
            #expect(image.orientation == .right)
        }
    #endif
}

private struct ImageTool: AnyLanguageModel.Tool {
    let name = "image"
    let description = "Return an image"
    let output: AnyLanguageModel.Prompt
    var parameters: AnyLanguageModel.GenerationSchema { String.generationSchema }
    func call(arguments: String) async throws -> AnyLanguageModel.Prompt { output }
}

#if canImport(FoundationModels) && compiler(>=6.4) && !os(tvOS) && !os(watchOS)
    @available(macOS 27, iOS 27, visionOS 27, *)
    private struct BridgeModel: FoundationModels.LanguageModel {
        typealias Executor = BridgeExecutor
        var callsTools = false
        var capabilities: FoundationModels.LanguageModelCapabilities { .init([.vision, .toolCalling]) }
        var executorConfiguration: String { "bridge-fixture" }
    }

    @available(macOS 27, iOS 27, visionOS 27, *)
    private struct BridgeExecutor: FoundationModels.LanguageModelExecutor {
        init(configuration: String) {}
        func respond(
            to request: FoundationModels.LanguageModelExecutorGenerationRequest,
            model: BridgeModel,
            streamingInto channel: FoundationModels.LanguageModelExecutorGenerationChannel
        ) async throws {
            if model.callsTools
                && !request.transcript.contains(where: {
                    if case .toolOutput = $0 { return true }; return false
                })
            {
                await channel.send(
                    .toolCalls(
                        action: .toolCall(
                            id: "image-call",
                            name: "image",
                            action: .appendArguments(#""read""#, tokenCount: 1)
                        )
                    )
                )
            } else {
                await channel.send(.response(action: .appendText("OK", tokenCount: 1)))
            }
        }
    }
#endif
