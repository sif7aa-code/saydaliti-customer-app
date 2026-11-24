import Flutter
import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif

/// إشعارات آيفون:
///  - المسار الأساسي Firebase (تطبيق iOS في مشروع `diqarapp`): عند وجود
///    `GoogleService-Info.plist` تُهيّأ Firebase ويتولّى `firebase_messaging`
///    الاستقبال والنقر (بما فيه الإقلاع من إشعار والتطبيق مغلق).
///  - مسار احتياطي APNs مباشر بلا Firebase: يبقى جاهزاً لأي بناء عادٍ بلا
///    ملف الإعداد، فيسجّل الجهاز لدى آبل ويمرّر التوكن والنقرة إلى Dart.
///    لا يعمل المسارَان معاً: وجود الملف يعني Firebase وحده.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let channelName = "saydaliti/apns"
  private static let tokenKey = "saydaliti_apns_token"

  private var pushChannel: FlutterMethodChannel?
  private var dartReady = false
  private var pendingTap: [String: String]?

  /// هل تهيّأ Firebase من ملف الحزمة؟ حينها مستمع `firebase_messaging`
  /// هو من يجب أن يبقى على `UNUserNotificationCenter` — تغطيته بمستمعنا
  /// تقطع النقر واستقبال الرسائل.
  private var firebaseReady = false

  /// مستمع إشعارات النظام في كائن مستقل: `FlutterAppDelegate` يفوّض
  /// `UNUserNotificationCenterDelegate` داخلياً ولا يكشفه في الـheader،
  /// فكتابة `override` عليه قد لا تترجم. الكائن المستقل صريح التزاماً.
  private lazy var notificationDelegate = ApnsNotificationDelegate(owner: self)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let remote = launchOptions?[.remoteNotification] as? [String: Any] {
      pendingTap = Self.stringify(remote)
    }
    #if canImport(FirebaseCore)
    if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
      FirebaseApp.configure()
      firebaseReady = true
    }
    #endif
    application.registerForRemoteNotifications()
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // بعد super (تسجيل الإضافات) حتى لا يُستبدل مستمع FCM إن كان مفعّلاً.
    if !firebaseReady {
      UNUserNotificationCenter.current().delegate = notificationDelegate
    }
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if !firebaseReady {
      UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    guard
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SaydalitiApnsBridge")
    else {
      return
    }
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "ready":
        self.dartReady = true
        result(nil)
      case "getToken":
        result(UserDefaults.standard.string(forKey: Self.tokenKey) ?? "")
      case "getLaunchTap":
        let tap = self.pendingTap
        self.pendingTap = nil
        result(tap)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    pushChannel = channel
    if !firebaseReady {
      UNUserNotificationCenter.current().delegate = notificationDelegate
    }
  }

  // MARK: - APNs token

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(token, forKey: Self.tokenKey)
    if dartReady {
      pushChannel?.invokeMethod("token", arguments: token)
    }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pushChannel?.invokeMethod("tokenError", arguments: error.localizedDescription)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// تُستدعى من مستمع النظام عند ضغط المستخدم على الإشعار — ومع التطبيق
  /// المقتول تُستدعى بعد إقلاع العملية، فإن لم تكن القناة جاهزة تُحفظ
  /// الحمولة إلى أن يسأل عنها Dart (`getLaunchTap`).
  fileprivate func handleNotificationTap(_ payload: [String: String]) {
    if dartReady {
      pushChannel?.invokeMethod("tap", arguments: payload)
    } else {
      pendingTap = payload
    }
  }

  /// قيم userInfo قد تحمل أرقاماً أو أنواعاً غير نصية (aps) — نمرّر
  /// النصوص وحدها، وفيها orderId/serial/kind/title/body/link.
  fileprivate static func stringify(_ info: [AnyHashable: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in info {
      guard let k = key as? String, k != "aps" else { continue }
      if let s = value as? String {
        out[k] = s
      } else if let n = value as? NSNumber {
        out[k] = n.stringValue
      }
    }
    return out
  }
}

/// مستمع إشعارات النظام: يعرض الإشعار والتطبيق مفتوح، ويمرّر النقرة للجسر.
private final class ApnsNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  private weak var owner: AppDelegate?

  init(owner: AppDelegate) {
    self.owner = owner
    super.init()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound, .badge])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let payload = AppDelegate.stringify(response.notification.request.content.userInfo)
    owner?.handleNotificationTap(payload)
    completionHandler()
  }
}
