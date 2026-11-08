import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // long: Cmd+Q、Dock 退出和红色关闭按钮走同一保存流程，防止下载和听时账本被直接中断。
    if let window = mainFlutterWindow, window.isVisible {
      window.performClose(nil)
      return .terminateCancel
    }
    return .terminateNow
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
