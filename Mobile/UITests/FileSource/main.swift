import Foundation
import UIKit

// 在另一个应用的沙盒里创建文稿，Files 必须把真实的读写权限交给 SkyFolio。
final class FileSource: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let file = URL.documentsDirectory.appendingPathComponent("From Files.csv")
        do { try Data("31,93\n".utf8).write(to: file, options: .atomic) }
        catch { fatalError("Could not create picker fixture: \(error)") }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(FileSource.self))
