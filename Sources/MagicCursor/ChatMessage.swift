import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
  enum Role: Equatable, Sendable {
    case user, assistant
  }

  enum Status: Equatable, Sendable {
    case streaming, complete, cancelled, failed
  }

  let id = UUID()
  let role: Role
  var content: String
  var status: Status = .complete
  var errorMessage: String?

  /// Assistant replies often contain inline Markdown such as `**bold**`.
  /// Only inline syntax is interpreted; whitespace is preserved so line breaks
  /// and `-` bullet lines still read naturally. Unclosed markers while
  /// streaming stay literal until they close.
  var formatted: AttributedString {
    (try? AttributedString(
      markdown: content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(content)
  }

  /// The reply without Markdown markers, for copying and reading aloud.
  var plainText: String { String(formatted.characters) }
}
