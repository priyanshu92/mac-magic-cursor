import Foundation

/// A short conversation title and up to three tappable follow-up prompts.
public struct SelectionInsights: Equatable, Sendable {
  public var title: String?
  public var suggestions: [String]

  public init(title: String? = nil, suggestions: [String] = []) {
    self.title = title
    self.suggestions = suggestions
  }

  public static let maximumSuggestions = 3
  public static let maximumSuggestionLength = 50
  public static let maximumTitleLength = 40

  /// Parses the model's plain-text insight response.
  ///
  /// The prompt asks for this shape, but small on-device models drift, so the
  /// parser tolerates common variants:
  ///
  ///     Title: Supplier portal PR
  ///     - Summarize the key changes
  ///     2. "What does this PR fix?"
  ///     • Draft a review comment
  ///
  /// Lines may use `-`, `*`, `•`, or `1.`/`1)` markers, and quotes or trailing
  /// periods may wrap a suggestion. A bare first line without `Title:` is not
  /// treated as a title, because that is usually a stray preamble.
  public static func parse(_ response: String) -> SelectionInsights {
    var result = SelectionInsights()
    var seen = Set<String>()
    for rawLine in response.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if let range = line.range(of: "title:", options: [.caseInsensitive, .anchored]) {
        let title = clean(String(line[range.upperBound...]))
        if result.title == nil, !title.isEmpty {
          result.title = String(title.prefix(maximumTitleLength))
        }
        continue
      }
      guard let marker = listMarkerEnd(in: line) else { continue }
      line = clean(String(line[marker...]))
      guard line.count >= 3, line.count <= maximumSuggestionLength else { continue }
      let key = line.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.suggestions.append(line)
      if result.suggestions.count == maximumSuggestions { break }
    }
    return result
  }

  private static func listMarkerEnd(in line: String) -> String.Index? {
    if let first = line.first, "-*•–".contains(first) {
      return line.index(after: line.startIndex)
    }
    let digits = line.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 2 else { return nil }
    let afterDigits = line.index(line.startIndex, offsetBy: digits.count)
    guard afterDigits < line.endIndex, ".)".contains(line[afterDigits]) else { return nil }
    return line.index(after: afterDigits)
  }

  private static func clean(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespaces)
    let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "`", "*"]
    while let first = value.first, quotes.contains(first) { value.removeFirst() }
    while let last = value.last, quotes.contains(last) { value.removeLast() }
    value = value.trimmingCharacters(in: .whitespaces)
    if value.hasSuffix("."), !value.hasSuffix("..") { value.removeLast() }
    return value.trimmingCharacters(in: .whitespaces)
  }
}
