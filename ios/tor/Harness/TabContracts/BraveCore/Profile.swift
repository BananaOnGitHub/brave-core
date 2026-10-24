// Test-only stand-in for the one BraveCore interface used by TorTabState.
public protocol Profile: AnyObject {
  var isOffTheRecord: Bool { get }
}
