import Darwin
import XCTest

class RunnerTests: XCTestCase {

  // Dart binds these through DynamicLibrary.process(), so they must survive linking and stripping.
  func testBridgeSymbolsAreLinked() {
    let process = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    for symbol in ["TincanFree", "TincanAttachEvents", "TincanNextEvent"] {
      XCTAssertNotNil(dlsym(process, symbol), "\(symbol) missing; run gobridge/build-ios.sh")
    }
  }

}
