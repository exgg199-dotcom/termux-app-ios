import XCTest
@testable import TermuxTerminal

final class ApcTest: TerminalTestCase {

    func testApcConsumed() {
        withTerminalSized(2, 2)
            .enterString("\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\")
            .assertLinesAre("  ", "  ");

        withTerminalSized(12, 2)
            .enterString("hello \u{1B}_some\u{13}\u{1B}_\\apc#end\u{1B}\\ world")
            .assertLinesAre("hello  world", "            ");
    }

}
