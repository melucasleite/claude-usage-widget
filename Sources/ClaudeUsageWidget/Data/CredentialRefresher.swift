import Foundation

/// Nudges Claude Code into refreshing its own OAuth credential.
///
/// ## Why this exists
///
/// The credential expires every few hours. The `claude` CLI refreshes it and
/// writes the new value to the Keychain — but the desktop app keeps an entirely
/// separate session (an Electron cookie jar under `Claude Safe Storage`, not an
/// OAuth token), so someone who works mainly in the desktop app can go days
/// without the CLI's copy being touched. The widget then goes dark through no
/// fault of theirs, and "run `claude` in a terminal" is a poor answer to give
/// someone who was not using the terminal in the first place.
///
/// `claude auth status` reports authentication state, **consumes no usage**,
/// and refreshes the stored token when it needs refreshing. So on a 401 the
/// widget runs it once and retries, rather than reporting failure and waiting
/// for a human.
///
/// ## What this deliberately does not do
///
/// It does not touch the refresh token itself. OAuth refresh tokens commonly
/// rotate, and spending one behind Claude Code's back could invalidate its
/// session — breaking the very thing the widget depends on. Delegating to the
/// CLI keeps that entirely in the hands of the tool that owns it.
enum CredentialRefresher {

  /// Where `claude` tends to live. An app launched from Finder inherits a
  /// minimal PATH — often just `/usr/bin:/bin:/usr/sbin:/sbin` — so relying on
  /// PATH alone means this silently never works outside a terminal.
  static var candidatePaths: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      "\(home)/.local/bin/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      "\(home)/.claude/local/claude",
    ]
  }

  /// Locates the CLI, preferring known install locations over PATH.
  static func locate() -> URL? {
    let fm = FileManager.default
    for path in candidatePaths where fm.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    // Last resort: ask the shell, which may have a fuller PATH than we do.
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    which.arguments = ["which", "claude"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = FileHandle.nullDevice
    guard (try? which.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    which.waitUntilExit()
    guard which.terminationStatus == 0,
      let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty, fm.isExecutableFile(atPath: path)
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  enum Outcome: Equatable {
    case refreshed
    case cliNotFound
    case failed(String)

    var succeeded: Bool { self == .refreshed }
  }

  /// Runs `claude auth status`, which refreshes the token if it is stale.
  ///
  /// Output is discarded rather than parsed: it contains the account email and
  /// organisation, none of which this app has any business keeping. Only
  /// success or failure matters here.
  static func refresh(timeout: TimeInterval = 25) async -> Outcome {
    guard let claude = locate() else { return .cliNotFound }

    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = claude
        process.arguments = ["auth", "status"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
          try process.run()
        } catch {
          continuation.resume(returning: .failed(error.localizedDescription))
          return
        }

        // Do not let a hung CLI hold the refresh loop open indefinitely.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
          Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
          process.terminate()
          continuation.resume(returning: .failed("`claude auth status` timed out"))
          return
        }

        continuation.resume(
          returning: process.terminationStatus == 0
            ? .refreshed
            : .failed("`claude auth status` exited \(process.terminationStatus)"))
      }
    }
  }
}
