import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'bluetooth_classic_service.dart';
import 'local_network_service.dart';
import 'qr_friend_store.dart';
import 'wifi_aware_service.dart';

/// Coordinates the local-only transports. Wi-Fi Aware performs its native
/// peer-to-peer data-path negotiation; LAN advertises peers on the same
/// broadcast domain; Bluetooth keeps an RFCOMM listener available.
///
/// Important: Bluetooth discovery is not identity/authentication. This
/// manager deliberately does not connect to every visible/bonded device.
/// Outgoing Bluetooth auto-connect must be limited to devices explicitly
/// linked to an accepted Blousab friend.
class NearbyConnectionManager with WidgetsBindingObserver {
  NearbyConnectionManager._();
  static final NearbyConnectionManager instance = NearbyConnectionManager._();

  final ValueNotifier<bool> running = ValueNotifier<bool>(false);
  final ValueNotifier<String> lastStatus = ValueNotifier<String>('غير مهيأ');
  Timer? _retryTimer;
  Future<void>? _startInFlight;
  String _userId = '';
  String _userName = 'مستخدم بلوساب';
  bool _enabled = true;
  bool _observerAttached = false;

  Future<void> start({
    required String userId,
    required String userName,
    bool enabled = true,
  }) async {
    _userId = userId.trim();
    _userName = userName.trim().isEmpty ? 'مستخدم بلوساب' : userName.trim();
    _enabled = enabled && _userId.isNotEmpty;
    if (!_observerAttached) {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    }
    if (!_enabled) {
      await stop();
      return;
    }
    await _runStartPass();
    _retryTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_runStartPass());
    });
  }

  Future<void> _runStartPass() {
    final active = _startInFlight;
    if (active != null) return active;
    final task = _startTransports();
    _startInFlight = task;
    task.whenComplete(() {
      if (identical(_startInFlight, task)) _startInFlight = null;
    });
    return task;
  }

  Future<void> _startTransports() async {
    if (!_enabled || _userId.isEmpty) return;
    final outcomes = <String>[];

    // Bluetooth Classic: make this phone accept incoming RFCOMM connections.
    // Android may require the user to enable Bluetooth and grant Nearby Devices.
    try {
      final bt = BluetoothClassicService.instance;
      if (await bt.isSupported() && await bt.requestPermissions() &&
          await bt.isEnabled()) {
        await bt.startServer();
        outcomes.add('Bluetooth استقبال جاهز');
      } else {
        outcomes.add('Bluetooth غير متاح/الصلاحيات غير مكتملة');
      }
    } catch (e) {
      outcomes.add('Bluetooth: تعذر التشغيل');
    }

    // Wi-Fi Aware negotiates a direct NAN data path without a router or Internet.
    try {
      // Only accepted Blousab friends may trigger an automatic Wi-Fi Aware
      // data-path. Other nearby users remain discoverable without auto-joining.
      final friends = await QrFriendStore.loadFriends();
      await WifiAwareService.instance.start(
        userId: _userId,
        userName: _userName,
        friendIds: friends,
      );
      await WifiAwareService.instance.updateFriends(friends);
      outcomes.add('Wi-Fi Aware يعمل (اتصال تلقائي بالأصدقاء فقط)');
    } catch (e) {
      outcomes.add('Wi-Fi Aware غير متاح على هذا الجهاز');
    }

    // LAN fallback: only works when devices share the same local Wi-Fi network
    // or the same Blousab local-only hotspot.
    try {
      await LocalNetworkService.instance.start(
        userId: _userId,
        userName: _userName,
      );
      outcomes.add('اكتشاف الشبكة المحلية يعمل');
    } catch (e) {
      outcomes.add('الشبكة المحلية غير متاحة');
    }

    running.value = outcomes.any((s) =>
        s.contains('جاهز') || s.contains('يعمل') || s.contains('قيد البدء'));
    lastStatus.value = outcomes.join(' • ');
  }

  Future<void> stop() async {
    _enabled = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    try { await WifiAwareService.instance.stop(); } catch (_) {}
    try { await LocalNetworkService.instance.stop(); } catch (_) {}
    try { await BluetoothClassicService.instance.stopServer(); } catch (_) {}
    running.value = false;
    lastStatus.value = 'متوقف';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _enabled) {
      unawaited(_runStartPass());
    }
  }

  void disposeObserver() {
    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }
  }
}
