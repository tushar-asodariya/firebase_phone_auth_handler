part of 'auth_handler.dart';

class FirebasePhoneAuthController extends ChangeNotifier {
  static FirebasePhoneAuthController _of(
    BuildContext context, {
    bool listen = true,
  }) =>
      Provider.of<FirebasePhoneAuthController>(context, listen: listen);

  /// {@macro autoRetrievalTimeOutDuration}
  static const kAutoRetrievalTimeOutDuration = Duration(seconds: 60);

  /// Firebase auth instance using the default [FirebaseApp].
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Web confirmation result for OTP.
  ConfirmationResult? _webConfirmationResult;

  /// {@macro recaptchaVerifierForWeb}
  RecaptchaVerifier? _recaptchaVerifierForWeb;

  /// The [_forceResendingToken] obtained from [codeSent]
  /// callback to force re-sending another verification SMS before the
  /// auto-retrieval timeout.
  int? _forceResendingToken;

  /// {@macro phoneNumber}
  String? _phoneNumber;

  /// The phone auth verification ID.
  String? _verificationId;

  /// Timer object for SMS auto-retrieval.
  Timer? _timer;

  /// Whether OTP to the given phoneNumber is sent or not.
  bool codeSent = false;

  /// Whether OTP is being sent to the given phoneNumber.
  bool get isSendingCode => !codeSent;

  /// Whether the current platform is web or not;
  bool get isWeb => kIsWeb;

  /// {@macro signOutOnSuccessfulVerification}
  late bool _signOutOnSuccessfulVerification;

  /// {@macro onCodeSent}
  VoidCallback? _onCodeSent;

  /// {@macro onLoginSuccess}
  OnLoginSuccess? _onLoginSuccess;

  /// {@macro onLoginFailed}
  OnLoginFailed? _onLoginFailed;

  /// Set callbacks and other data. (only for internal use)
  void _setData({
    required String phoneNumber,
    required OnLoginSuccess? onLoginSuccess,
    required OnLoginFailed? onLoginFailed,
    required VoidCallback? onCodeSent,
    required bool signOutOnSuccessfulVerification,
    RecaptchaVerifier? recaptchaVerifierForWeb,
    Duration autoRetrievalTimeOutDuration = kAutoRetrievalTimeOutDuration,
  }) {
    _phoneNumber = phoneNumber;
    _signOutOnSuccessfulVerification = signOutOnSuccessfulVerification;
    _onLoginSuccess = onLoginSuccess;
    _onCodeSent = onCodeSent;
    _onLoginFailed = onLoginFailed;
    _autoRetrievalTimeOutDuration = autoRetrievalTimeOutDuration;
    if (kIsWeb) _recaptchaVerifierForWeb = recaptchaVerifierForWeb;
  }

  /// After a [Duration] of [timerCount], the library no more waits for SMS auto-retrieval.
  Duration get timerCount =>
      Duration(seconds: _autoRetrievalTimeOutDuration.inSeconds - (_timer?.tick ?? 0));

  /// Whether the timer is active or not.
  bool get timerIsActive => _timer?.isActive ?? false;

  /// {@macro autoRetrievalTimeOutDuration}
  static Duration _autoRetrievalTimeOutDuration = kAutoRetrievalTimeOutDuration;

  /// Verify the OTP sent to [_phoneNumber] and login user is OTP was correct.
  ///
  /// Returns true if the [otp] passed was correct and the user was logged in successfully.
  /// On login success, [_onLoginSuccess] is called.
  ///
  /// If the [otp] passed is incorrect, or the [otp] is expired or any other
  /// error occurs, the functions returns false.
  ///
  /// Also, [_onLoginFailed] is called with [FirebaseAuthException]
  /// object to handle the error.
  Future<bool> verifyOTP(String otp) async {
    if ((!kIsWeb && _verificationId == null) ||
        (kIsWeb && _webConfirmationResult == null)) return false;
    try {
      if (kIsWeb) {
        final userCredential = await _webConfirmationResult!.confirm(otp);
        return await _loginUser(
          userCredential: userCredential,
          autoVerified: false,
        );
      } else {
        final credential = PhoneAuthProvider.credential(
          verificationId: _verificationId!,
          smsCode: otp,
        );
        return await _loginUser(
          authCredential: credential,
          autoVerified: false,
        );
      }
    } on FirebaseAuthException catch (e) {
      _onLoginFailed?.call(e);
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Send OTP to the given [_phoneNumber].
  ///
  /// Returns true if OTP was sent successfully.
  ///
  /// If for any reason, the OTP is not send,
  /// [_onLoginFailed] is called with [FirebaseAuthException]
  /// object to handle the error.
  Future<bool> sendOTP() async {
    codeSent = false;
    await Future.delayed(Duration.zero, notifyListeners);

    verificationCompletedCallback(AuthCredential authCredential) async {
      await _loginUser(authCredential: authCredential, autoVerified: true);
    }

    verificationFailedCallback(FirebaseAuthException authException) {
      _onLoginFailed?.call(authException);
    }

    codeSentCallback(
      String verificationId, [
      int? forceResendingToken,
    ]) async {
      _verificationId = verificationId;
      _forceResendingToken = forceResendingToken;
      codeSent = true;
      _onCodeSent?.call();
      notifyListeners();
      _setTimer();
    }

    codeAutoRetrievalTimeoutCallback(String verificationId) {
      _verificationId = verificationId;
    }

    try {
      if (kIsWeb) {
        _webConfirmationResult = await _auth.signInWithPhoneNumber(
          _phoneNumber!,
          _recaptchaVerifierForWeb,
        );
        codeSent = true;
        _onCodeSent?.call();
        _setTimer();
      } else {
        await _auth.verifyPhoneNumber(
          phoneNumber: _phoneNumber!,
          verificationCompleted: verificationCompletedCallback,
          verificationFailed: verificationFailedCallback,
          codeSent: codeSentCallback,
          codeAutoRetrievalTimeout: codeAutoRetrievalTimeoutCallback,
          timeout: _autoRetrievalTimeOutDuration,
          forceResendingToken: _forceResendingToken,
        );
      }

      return true;
    } on FirebaseAuthException catch (e) {
      _onLoginFailed?.call(e);
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Called when the otp is verified either automatically (OTP auto fetched)
  /// or [verifyOTP] was called with the correct OTP.
  ///
  /// If true is returned that means the user was logged in successfully.
  ///
  /// If for any reason, the user fails to login,
  /// [_onLoginFailed] is called with [FirebaseAuthException]
  /// object to handle the error and false is returned.
  Future<bool> _loginUser({
    AuthCredential? authCredential,
    UserCredential? userCredential,
    required bool autoVerified,
  }) async {
    if (kIsWeb) {
      if (userCredential != null) {
        if (_signOutOnSuccessfulVerification) await signOut();
        _onLoginSuccess?.call(userCredential, autoVerified);
        return true;
      } else {
        return false;
      }
    }

    // Not on web.
    try {
      final authResult = await _auth.signInWithCredential(authCredential!);
      if (_signOutOnSuccessfulVerification) await signOut();
      _onLoginSuccess?.call(authResult, autoVerified);
      return true;
    } on FirebaseAuthException catch (e) {
      _onLoginFailed?.call(e);
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Set timer after code sent.
  void _setTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timer.tick == _autoRetrievalTimeOutDuration.inSeconds) _timer?.cancel();
      try {
        notifyListeners();
      } catch (_) {}
    });
    notifyListeners();
  }

  /// {@macro signOut}
  Future<void> signOut() async {
    await _auth.signOut();
    // notifyListeners();
  }

  /// Clear all data
  void clear() {
    if (kIsWeb) {
      _recaptchaVerifierForWeb?.clear();
      _recaptchaVerifierForWeb = null;
    }
    codeSent = false;
    _webConfirmationResult = null;
    _onLoginSuccess = null;
    _onLoginFailed = null;
    _onCodeSent = null;
    _signOutOnSuccessfulVerification = false;
    _forceResendingToken = null;
    _timer?.cancel();
    _timer = null;
    _phoneNumber = null;
    _autoRetrievalTimeOutDuration = kAutoRetrievalTimeOutDuration;
    _verificationId = null;
  }
}
