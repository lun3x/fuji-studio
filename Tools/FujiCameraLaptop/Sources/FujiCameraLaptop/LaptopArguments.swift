import Foundation

enum LaptopError: Error, Equatable {
  case invalidArguments, outputExists, invalidSource, invalidRecipe, missingSlot, closeUnconfirmed
  case storage(Int32)
}
struct LaptopArguments: Sendable {
  enum Selection: Sendable {
    case slot(Int)
    case file(URL)
  }
  enum Operation: Sendable {
    case importRecipes
    case render(URL, Selection)
  }
  let operation: Operation, output: URL
  init(_ arguments: [String]) throws {
    guard let verb = arguments.first, ["import-recipes", "render"].contains(verb) else {
      throw LaptopError.invalidArguments
    }
    var values: [String: String] = [:]
    var index = 1
    while index < arguments.count {
      let flag = arguments[index]
      guard ["--output", "--raw", "--slot", "--recipe-file"].contains(flag), values[flag] == nil,
        index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--")
      else { throw LaptopError.invalidArguments }
      values[flag] = arguments[index + 1]
      index += 2
    }
    guard let output = values.removeValue(forKey: "--output"), !output.isEmpty else {
      throw LaptopError.invalidArguments
    }
    self.output = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
    if verb == "import-recipes" {
      guard values.isEmpty else { throw LaptopError.invalidArguments }
      operation = .importRecipes
      return
    }
    guard let raw = values.removeValue(forKey: "--raw"), !raw.isEmpty else {
      throw LaptopError.invalidArguments
    }
    let selection: Selection
    if let slot = values.removeValue(forKey: "--slot") {
      guard let number = Int(slot), number > 0 else { throw LaptopError.invalidArguments }
      selection = .slot(number)
    } else if let file = values.removeValue(forKey: "--recipe-file"), !file.isEmpty {
      selection = .file(URL(fileURLWithPath: file))
    } else {
      throw LaptopError.invalidArguments
    }
    guard values.isEmpty else { throw LaptopError.invalidArguments }
    operation = .render(URL(fileURLWithPath: raw).standardizedFileURL, selection)
  }
}
