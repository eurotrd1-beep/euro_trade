// No-op stub for the passkeys_web plugin (pulled transitively by supabase_flutter).
// The app does NOT use passkeys, but passkeys_web.registerWith() calls
// PasskeyAuthenticator.init() at startup and crashes the whole app with
// "Cannot read properties of undefined (reading 'init')" if this global is missing.
// Defining a harmless stub lets plugin registration succeed.
window.PasskeyAuthenticator = {
  init: function () {},
  register: function () { return Promise.reject('passkeys not supported'); },
  login: function () { return Promise.reject('passkeys not supported'); },
  cancelCurrentAuthenticatorOperation: function () {},
  isUserVerifyingPlatformAuthenticatorAvailable: function () { return Promise.resolve(false); },
  isConditionalMediationAvailable: function () { return Promise.resolve(false); },
  hasPasskeySupport: function () { return false; }
};
