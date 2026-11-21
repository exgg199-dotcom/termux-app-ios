import XCTest
@testable import TermuxTerminal

final class ApcTest: TerminalTestCase {

    func testApcConsumed() {
        // At time of writing this is part of what yazi sends for probing for kitty graphics protocol support:
        // https://github.com/sxyazi/yazi/blob/0cdaff98d0b3723caff63eebf1974e7907a43a2c/yazi-adapter/src/emulator.rs#L129
        // This should not result in anything being written to the screen: If kitty graphics protocol support
        // is implemented it should instead result in an error code on stdin, and if not it should be consumed
        // silently just as xterm does. See https://sw.kovidgoyal.net/kitty/graphics-protocol/.
        withTerminalSized(2, 2)
            .enterString("\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\")
            .assertLinesAre("  ", "  ");

        // It is ok for the APC content to be non printable characters:
        withTerminalSized(12, 2)
            .enterString("hello \u{1B}_some\u{13}\u{1B}_\\apc#end\u{1B}\\ world")
            .assertLinesAre("hello  world", "            ");
    }

}
