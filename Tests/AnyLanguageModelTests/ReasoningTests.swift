import Foundation
import Testing

@testable import AnyLanguageModel

@Suite("Reasoning transcript")
struct ReasoningTests {
    @Test func codablePreservesOpaqueSignatureAndMetadata() throws {
        let reasoning = Transcript.Reasoning(
            id: "reason",
            metadata: ["provider": GeneratedContent("fixture"), "redacted": GeneratedContent(true)],
            segments: [.text(.init(id: "segment", content: "Summary"))],
            signature: Data([0, 255, 16])
        )
        let transcript = Transcript(entries: [.reasoning(reasoning)])
        #expect(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript)) == transcript)
        #expect(transcript.first?.id == "reason")
        #expect(!transcript.first!.description.contains("255"))
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func originalInitializerFunctionReferencesCompile() async throws {
        let responseInit = LanguageModelSession.Response<String>.init(content:rawContent:transcriptEntries:usage:)
        let snapshotInit = LanguageModelSession.ResponseStream<String>.Snapshot.init(
            content:
            rawContent:
            transcriptEntries:
            usage:
        )
        let streamInit = LanguageModelSession.ResponseStream<String>.init(content:rawContent:usage:)
        let raw = GeneratedContent("Answer")
        #expect(responseInit("Answer", raw, [], .zero).content == "Answer")
        #expect(snapshotInit("Answer", raw, [], .zero).content == "Answer")
        #expect(try await streamInit("Answer", raw, .zero).collect().content == "Answer")
    }

    @Test func cumulativeEntriesPersistOnceAndDoNotPolluteAnswer() async throws {
        let session = LanguageModelSession(model: ReasoningModel())
        var ids: [String] = []
        for try await snapshot in session.streamResponse(to: "Question") {
            ids.append(try #require(snapshot.transcriptEntries.first?.id))
            let visible: String = snapshot.content
            #expect(!visible.contains("First"))
        }
        #expect(Set(ids) == ["reason"])
        #expect(session.transcript.count == 3)
        guard case .reasoning(let reasoning) = session.transcript[1] else { Issue.record("Missing reasoning"); return }
        #expect(reasoning.segments == [.text(.init(id: "segment", content: "First second"))])
        guard case .response(let answer) = session.transcript[2] else { Issue.record("Missing answer"); return }
        #expect(answer.segments.count == 1)
        #expect(answer.segments.first?.description == "Answer")
    }

    @Test func nonstreamAndSchemaRetainEntries() async throws {
        let session = LanguageModelSession(model: ReasoningModel())
        let response = try await session.respond(to: "Question", schema: String.generationSchema)
        #expect(response.transcriptEntries.count == 1)
        #expect(response.rawContent == GeneratedContent("Answer"))
        let streamed = try await session.streamResponse(to: "Again", schema: String.generationSchema).collect()
        #expect(streamed.transcriptEntries.count == 1)
        #expect(streamed.rawContent == GeneratedContent("Answer"))
    }

    @Test(arguments: [TranscriptErrorHandlingPolicy.preserveTranscript, .revertTranscript])
    func failureRetainsCheckpointAccordingToPolicy(policy: TranscriptErrorHandlingPolicy) async throws {
        let old = Transcript.Entry.prompt(.init(id: "old", segments: [.text(.init(content: "Old"))]))
        let session = LanguageModelSession(model: ReasoningModel(fails: true), transcript: Transcript(entries: [old]))
        session.transcriptErrorHandlingPolicy = policy
        await #expect(throws: CancellationError.self) {
            for try await _ in session.streamResponse(to: "Question") {}
        }
        if policy == .revertTranscript {
            #expect(Array(session.transcript) == [old])
        } else {
            #expect(session.transcript.count == 5)
            #expect(session.transcript.filter { if case .reasoning = $0 { true } else { false } }.count == 1)
            #expect(session.transcript.filter { if case .toolOutput = $0 { true } else { false } }.count == 1)
            #expect(!session.transcript.contains { if case .response = $0 { true } else { false } })
        }
    }

    @Test(arguments: [false, true])
    func consumerCancellationWaitsForTranscriptCleanup(completedTool: Bool) async throws {
        let session = LanguageModelSession(
            model: ReasoningModel(waitsUntilCancelled: true, completedTool: completedTool)
        )
        session.transcriptErrorHandlingPolicy = .preserveTranscript
        let consumer = Task {
            for try await _ in session.streamResponse(to: "Question") {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        _ = await consumer.result
        await session.waitForResponseCompletion()
        #expect(!session.isResponding)
        #expect(session.transcript.count == (completedTool ? 4 : 2))
        #expect(session.transcript.filter { if case .reasoning = $0 { true } else { false } }.count == 1)
        #expect(!session.transcript.contains { if case .response = $0 { true } else { false } })
    }

    @Test func nonstreamFailureRevertsPrompt() async throws {
        let session = LanguageModelSession(model: ReasoningModel(fails: true))
        session.transcriptErrorHandlingPolicy = .revertTranscript
        await #expect(throws: CancellationError.self) { _ = try await session.respond(to: "Question") }
        #expect(session.transcript.isEmpty)
    }

    @Test func defaultFailureRetainsOnlyPrompt() async throws {
        let session = LanguageModelSession(model: ReasoningModel(fails: true))
        await #expect(throws: CancellationError.self) {
            for try await _ in session.streamResponse(to: "Question") {}
        }
        #expect(session.transcript.count == 1)
    }
}

private struct ReasoningModel: LanguageModel {
    typealias UnavailableReason = Never
    var fails = false
    var waitsUntilCancelled = false
    var completedTool = false

    func respond<Content: Generable>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        try await streamResponse(
            within: session,
            to: prompt,
            generating: type,
            includeSchemaInPrompt: includeSchemaInPrompt,
            options: options
        ).collect()
    }

    func streamResponse<Content: Generable>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> {
        .init(
            stream: AsyncThrowingStream { continuation in
                do {
                    for (text, reasoning) in [("", "First"), ("", "First second"), ("Answer", "First second")] {
                        let raw = GeneratedContent(text)
                        var entries: [Transcript.Entry] = [
                            .reasoning(
                                .init(
                                    id: "reason",
                                    segments: [.text(.init(id: "segment", content: reasoning))]
                                )
                            )
                        ]
                        if fails || completedTool {
                            entries.append(
                                .toolCalls(
                                    .init(
                                        id: "calls",
                                        [.init(id: "call", toolName: "fixture", arguments: GeneratedContent("{}"))]
                                    )
                                )
                            )
                            entries.append(
                                .toolOutput(
                                    .init(id: "call", toolName: "fixture", segments: [.text(.init(content: "Done"))])
                                )
                            )
                        }
                        continuation.yield(
                            .init(
                                content: try Content(raw).asPartiallyGenerated(),
                                rawContent: raw,
                                transcriptEntries: ArraySlice(entries)
                            )
                        )
                        if fails { throw CancellationError() }
                        if waitsUntilCancelled { return }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        )
    }
}
