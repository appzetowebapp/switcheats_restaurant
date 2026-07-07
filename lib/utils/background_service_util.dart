import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:webview_master_app/config/app_config.dart';

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  AudioPlayer? audioPlayer;
  bool isRinging = false;
  Timer? notificationDismissTimer;

  Future<void> stopRingtoneSound() async {
    notificationDismissTimer?.cancel();
    notificationDismissTimer = null;
    if (isRinging) {
      debugPrint('🔕 Background Service: Stopping Ringtone');
      isRinging = false;
      await audioPlayer?.stop();
      await audioPlayer?.dispose();
      audioPlayer = null;

      if (service is AndroidServiceInstance) {
        // Reset notification info
        service.setForegroundNotificationInfo(
          title: "SwitchEats Partner Service Active",
          content: "Waiting for new orders...",
        );
      }
    }
  }

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });

    // Set initial notification content once
    service.setForegroundNotificationInfo(
      title: "SwitchEats Partner Service Active",
      content: "Waiting for new orders...",
    );

    // Listen for ringtone start.
    // NOTE: Do NOT call setForegroundNotificationInfo here.
    // The foreground-service notification (ID 888) must stay as the generic
    // "service is running" indicator. Changing it to order-related text creates
    // a second notification that looks identical to the critical order alert
    // already shown by showOrderNotification() — the duplicate the user sees.
    service.on('startRingtone').listen((event) async {
      if (!isRinging) {
        debugPrint('🔔 Background Service: Starting Ringtone');
        isRinging = true;
        // Create a fresh player each time so there is no stale ExoPlayer state.
        // Set the audio context on the new instance BEFORE loading the source so
        // the notification-stream AudioAttributes are applied during preparation —
        // this prevents the brief full-volume burst that occurs when attributes
        // are applied after ExoPlayer has already started audio output.
        audioPlayer = AudioPlayer();
        await audioPlayer!.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              contentType: AndroidContentType.sonification,
              usageType: AndroidUsageType.notification,
              audioFocus: AndroidAudioFocus.gainTransient,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.ambient,
            ),
          ),
        );
        await audioPlayer!.setReleaseMode(ReleaseMode.loop);
        // setSource prepares the player (AudioAttributes already in place),
        // then resume starts output — volume is correct from the very first frame.
        await audioPlayer!.setSource(AssetSource('audio/iphone-remix-68028.mp3'));
        await audioPlayer!.resume();
      } else {
        debugPrint('🔔 Background Service: New order while ringing — re-pointing dismiss watcher');
      }

      // Poll the system tray for the order notification. If it's no longer
      // present (user swiped it away, tapped "Clear all", or it auto-cancelled
      // on tap), the ringtone has nothing to point at — stop it immediately.
      //
      // Re-run this for every startRingtone call (even if already ringing) so
      // the watcher always tracks the most recently posted order notification.
      // Otherwise, if a second order arrives while the first is still ringing,
      // dismissing the FIRST order's notification would silence the ringtone
      // even though the SECOND order's notification is still in the tray.
      final notificationId = event?['notificationId'];
      if (notificationId is int) {
        notificationDismissTimer?.cancel();
        notificationDismissTimer = Timer.periodic(
          const Duration(seconds: 2),
          (timer) async {
            if (!isRinging) {
              timer.cancel();
              return;
            }
            try {
              final active = await FlutterLocalNotificationsPlugin()
                  .getActiveNotifications();
              final stillShown =
                  active.any((n) => n.id == notificationId);
              if (!stillShown) {
                await stopRingtoneSound();
              }
            } catch (e) {
              debugPrint('⚠️ Notification dismiss check failed: $e');
            }
          },
        );
      }
    });

    // Listen for ringtone stop
    service.on('stopRingtone').listen((event) async {
      await stopRingtoneSound();
    });
  }

  service.on('stopService').listen((event) async {
    notificationDismissTimer?.cancel();
    notificationDismissTimer = null;
    await audioPlayer?.dispose();
    audioPlayer = null;
    service.stopSelf();
  });

  // Location tracking logic (remains same)
  Timer.periodic(const Duration(seconds: 15), (timer) async {
    if (service is AndroidServiceInstance) {
      if (!(await service.isForegroundService())) {
        return;
      }

      try {
        final position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high);
        
        debugPrint('📍 Background Location: ${position.latitude}, ${position.longitude}');
        
        // Broadcast location update
        service.invoke('update', {
          "latitude": position.latitude,
          "longitude": position.longitude,
        });
      } catch (e) {
        debugPrint('❌ Background Location Error: $e');
      }
    }
  });
}

@pragma('vm:entry-point')
class BackgroundServiceUtil {
  static const int notificationId = 888;

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: AppConfig.silentChannelId,
        initialNotificationTitle: 'Restaurant service active',
        initialNotificationContent: 'Waiting for new orders...',
        foregroundServiceNotificationId: notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  static Future<void> start() async {
    final service = FlutterBackgroundService();
    var isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    var isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('stopService');
    }
  }

  static Future<bool> isRunning() async {
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }

  /// Start (if needed) the background service and invoke 'startRingtone'.
  ///
  /// `service.startService()` resolving only means the platform side
  /// acknowledged the request — the Dart isolate's onStart() still needs to
  /// run and register its `service.on('startRingtone')` listener before any
  /// invoke() will be received. On a cold start (Firebase init, plugin
  /// registration, etc.) that can take longer than a single fixed delay on
  /// slower devices, silently dropping the invoke and skipping the ringtone.
  /// Send the invoke multiple times over a few seconds — harmless because
  /// onStart()'s `isRinging` flag ignores any invokes after the first.
  static Future<void> startRingtone(Map<String, dynamic> payload) async {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    for (final delayMs in [0, 500, 1000, 2000, 3500]) {
      if (delayMs > 0) await Future.delayed(Duration(milliseconds: delayMs));
      service.invoke('startRingtone', payload);
    }
  }
}
