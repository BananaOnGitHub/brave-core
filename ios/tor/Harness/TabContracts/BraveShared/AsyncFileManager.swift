import Foundation

// Only the standard Downloads-directory lookup is substituted. Download and
// TorDownload are compiled from the real Web sources in the contract target.
public actor AsyncFileManager {
  public static let `default` = AsyncFileManager()
  public func downloadsPath() throws -> URL {
    FileManager.default.temporaryDirectory
  }
  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }
}
