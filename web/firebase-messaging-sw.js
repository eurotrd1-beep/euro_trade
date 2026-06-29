importScripts('https://www.gstatic.com/firebasejs/12.15.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/12.15.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyDrtwqVdGjfe7yzpgwzYN3JO19Nzi4ns9g',
  authDomain: 'euro-3c570.firebaseapp.com',
  projectId: 'euro-3c570',
  storageBucket: 'euro-3c570.firebasestorage.app',
  messagingSenderId: '859715185605',
  appId: '1:859715185605:web:b140078abb2f06e2faf9ac',
});

const messaging = firebase.messaging();
