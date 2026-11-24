// =====================================================================
//  عامل خدمة الإشعارات (FCM Web) — مشروع diqarapp
// =====================================================================
//
//  ★ لماذا هذا الملف في جذر الويب؟
//    `firebase_messaging` على الويب يسجّل هذا المسار تلقائياً
//    (`/firebase-messaging-sw.js`). بدونه يفشل `getToken` ولا يصبح
//    للمتصفح عنوان إشعار — أي يبقى صامتاً والتطبيق مغلق.
//
//  ★ الرسائل من الخادم تحمل `notification` (عنوان ونص) ⇒ يعرضها
//    الـSDK نفسه في شريط النظام حتى والموقع مغلق. النقر يفتح الرابط
//    المرفق في `fcm_options.link` (نُرسله من الخادم).
//
//  ★ إصدار JS SDK يطابق ما تتوقعه FlutterFire (12.19.0).
// =====================================================================

importScripts('https://www.gstatic.com/firebasejs/12.19.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/12.19.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyDFJpVhWb1-_M5TNzGAQnnO6nthr0QQMmQ',
  authDomain: 'diqarapp.firebaseapp.com',
  projectId: 'diqarapp',
  storageBucket: 'diqarapp.firebasestorage.app',
  messagingSenderId: '828586455121',
  appId: '1:828586455121:web:5293088b354fcd09408870',
});

// تهيئة المراسلة: بها يعرض الشخصُ الخلفي رسائل `notification`.
firebase.messaging();
