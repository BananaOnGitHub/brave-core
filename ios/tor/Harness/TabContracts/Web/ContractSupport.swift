extension String {
  // SafeJavaScript's string-argument support belongs to Shared in Brave. These
  // contracts exercise argument-free native scripts; fail if that scope grows.
  var htmlEntityEncodedString: String {
    preconditionFailure("Shared string escaping is outside this contract suite")
  }
}
// Tor tabs never create downloads. Only this type's identity is needed by the
// real TabDownloadDelegate protocol, without Brave's file-management services.
public class Download {}

