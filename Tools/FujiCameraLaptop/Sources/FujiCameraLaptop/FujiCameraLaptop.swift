import Darwin
import Foundation

@main enum FujiCameraLaptop {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let operation = Task {
      do {
        try await LaptopRunner.run(arguments: arguments)
        print("Shared-core camera operation completed; private evidence saved.")
        exit(0)
      } catch {
        fputs(
          "FujiCameraLaptop: \(error)\nUsage: import-recipes --output FRESH_DIRECTORY\n       render --raw FILE.RAF (--slot N | --recipe-file SNAPSHOT.json) --output FRESH_DIRECTORY\n",
          stderr)
        exit(Task.isCancelled ? 130 : 1)
      }
    }
    // ImageCaptureCore's selector/browser callbacks require a live main run loop.
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    interrupt.setEventHandler { operation.cancel() }
    terminate.setEventHandler { operation.cancel() }
    interrupt.resume()
    terminate.resume()
    withExtendedLifetime((interrupt, terminate)) { RunLoop.main.run() }
  }
}
