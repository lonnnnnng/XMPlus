import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // long: 隐藏窗口后退出也要先保存下载和听时账本，不能按窗口可见性跳过上游关闭流程。
    if let window = mainFlutterWindow, window.isVisible || window.isMiniaturized || sender.isHidden {
      // long: 先还原窗口，保存失败或下载确认时才能显示提示；真正关窗后的再次终止会直接放行。
      sender.unhide(nil)
      window.deminiaturize(nil)
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
