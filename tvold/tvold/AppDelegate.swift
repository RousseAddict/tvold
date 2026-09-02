import UIKit
import AVFoundation

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Before anything else: rotate the previous run's log aside and work
        // out whether that run ended on its own terms.
        CrashReport.beginSession()

        // The default SoloAmbient category is silenced by the ring/silent switch;
        // Playback ignores it. No setActive — the movie player activates it.
        try? AVAudioSession.sharedInstance().setCategory(.playback)

        let nav = UINavigationController(rootViewController: CountriesViewController())
        nav.navigationBar.barStyle = .black
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        CrashReport.stage("window-up")
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        DebugLog.shared.log("Memory", "WARNING from the system — \(DebugLog.residentMB())MB resident")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        CrashReport.endSession()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        CrashReport.resumeSession()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        CrashReport.endSession()
    }
}
