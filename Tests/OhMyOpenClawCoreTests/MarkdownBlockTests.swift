import Testing
@testable import OhMyOpenClawCore

@Test func longCodeFencePreservesNestedShorterFences() {
    let markdown = "````markdown\n```swift\nlet value = 1\n```\n````"
    #expect(MarkdownBlock.parse(markdown) == [.code("markdown", "```swift\nlet value = 1\n```")])
}

@Test func closingCodeFenceRequiresMatchingMarkerAndWhitespaceOnly() {
    let markdown = "~~~text\nvalue\n~~~not-a-closer\n```\nmore\n~~~~ \t"
    #expect(MarkdownBlock.parse(markdown) == [.code("text", "value\n~~~not-a-closer\n```\nmore")])
}

@Test func incompleteStreamingCodeFenceKeepsItsLiteralContents() {
    #expect(MarkdownBlock.parse("````swift\nlet value = 1\n```") == [.code("swift", "let value = 1\n```")])
}

@Test func backtickInOpeningInfoDoesNotStartCodeFence() {
    #expect(MarkdownBlock.parse("```bad`info\ntext") == [.paragraph("```bad`info\ntext")])
}
