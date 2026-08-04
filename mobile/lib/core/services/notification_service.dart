import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String alarmChannelId = 'geofence_alarm_channel_v2';
  static const String alarmChannelName = 'Smart Geofence Alarms';

  static const String serviceChannelId = 'geofence_service_channel';
  static const String serviceChannelName = 'Geofence Background Service';

  // Geriye dönük uyumluluk için varsayılan id
  static const String channelId = alarmChannelId;
  static const String channelName = alarmChannelName;

  static Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
    );

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse details) async {
        // Notification tap actions can be added here if needed
      },
    );

    // Explicitly create notification channels for Android 8+
    final androidPlugin = _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidPlugin != null) {
      // 1. Yüksek Öncelikli Alarm Kanalı (Sesli Modda Ses Çalar, Titreşim Modunda Titrer)
      const AndroidNotificationChannel alarmChannel = AndroidNotificationChannel(
        alarmChannelId,
        alarmChannelName,
        description: 'High priority notifications that trigger when approaching your destination',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin.createNotificationChannel(alarmChannel);

      // 2. Sessiz Arka Plan Servis Kanalı (Ses Çalmaz, Titremez)
      const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
        serviceChannelId,
        serviceChannelName,
        description: 'Silent persistent notification for background location tracking',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      );
      await androidPlugin.createNotificationChannel(serviceChannel);
    }
  }

  static Future<bool> requestPermissions() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<void> showAlert({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      alarmChannelId,
      alarmChannelName,
      channelDescription: 'High priority notifications that trigger when approaching your destination',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      styleInformation: BigTextStyleInformation(''),
    );

    const DarwinNotificationDetails iOSDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBadge: true,
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    await _notificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: payload,
    );
  }

  static Future<void> cancelAll() async {
    await _notificationsPlugin.cancelAll();
  }

  static Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id: id);
  }
}
