import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDrtwqVdGjfe7yzpgwzYN3JO19Nzi4ns9g',
    appId: '1:859715185605:web:b140078abb2f06e2faf9ac',
    messagingSenderId: '859715185605',
    projectId: 'euro-3c570',
    authDomain: 'euro-3c570.firebaseapp.com',
    databaseURL: 'https://euro-3c570-default-rtdb.firebaseio.com',
    storageBucket: 'euro-3c570.firebasestorage.app',
    measurementId: 'G-CL5QM49RW2',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDrtwqVdGjfe7yzpgwzYN3JO19Nzi4ns9g',
    appId: '1:859715185605:android:b140078abb2f06e2faf9ac',
    messagingSenderId: '859715185605',
    projectId: 'euro-3c570',
    databaseURL: 'https://euro-3c570-default-rtdb.firebaseio.com',
    storageBucket: 'euro-3c570.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDrtwqVdGjfe7yzpgwzYN3JO19Nzi4ns9g',
    appId: '1:859715185605:ios:b140078abb2f06e2faf9ac',
    messagingSenderId: '859715185605',
    projectId: 'euro-3c570',
    databaseURL: 'https://euro-3c570-default-rtdb.firebaseio.com',
    storageBucket: 'euro-3c570.firebasestorage.app',
    iosBundleId: 'com.eurotrade.app',
  );
}
