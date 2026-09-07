import 'package:alarm/alarm.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'hive_service.dart';

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

    // `alarm` paketi: STAGE_NEAR/varış gibi kritik anlarda sessiz modu/DND'yi
    // atlayan, döngüyle çalan gerçek alarm sesi için (bkz. ringAlarm). Her
    // izolatta (main + background service) ayrı çağrılması gerekir; birden
    // fazla çağrı güvenlidir.
    await Alarm.init();
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

  /// STAGE_NEAR ve varış gibi "kullanıcıyı uyandırma" anları için gerçek bir
  /// çalar saat gibi davranan alarm çalar: sessiz moddayken/Rahatsız Etmeyin
  /// açıkken bile duyulur (STREAM_ALARM / usageAlarm), ekranı uyandırır
  /// (full-screen intent) ve kullanıcı durdurana ya da [stopRingingAlarm]
  /// çağrılana kadar döngüyle, sesi kademeli artırarak çalmaya devam eder —
  /// tek seferlik bir bildirim sesi değildir.
  ///
  /// Aynı anda yalnızca tek bir hedefe yönelik takip yapıldığından, yeni bir
  /// aşama tetiklendiğinde önceki aşamanın alarmı varsa önce durdurulur;
  /// aksi halde ikisi kuyruğa girip yeni (daha acil) alarmın sesini geciktirir.
  static Future<void> ringAlarm({
    required int id,
    required String title,
    required String body,
  }) async {
    // Kullanıcının Ayarlar ekranından seçtiği ses düzeyi ve titreşim tercihi.
    // Bu fonksiyon arka plan izolatından da çağrıldığından burada okunuyor
    // (yalnızca okuma; HiveService'in diğer arka plan okumalarıyla aynı
    // güvenli örüntü — bkz. background_service.dart).
    final double volume = await HiveService.getAlarmVolume();
    final bool vibrate = await HiveService.getAlarmVibrate();

    await Alarm.stopAll();
    await Alarm.set(
      alarmSettings: AlarmSettings(
        id: id,
        // Neredeyse anında çalması için: geofence eşiği aşıldığı an tetiklenir,
        // ileri bir tarihe planlanan bir "alarm kur" değildir.
        dateTime: DateTime.now().add(const Duration(milliseconds: 300)),
        loopAudio: true,
        vibrate: vibrate,
        androidFullScreenIntent: true,
        // Uygulama arka planda öldürülse bile bu anlık alarmın tekrar
        // kurulacağı bir "gelecek alarm" olmadığından kapalı; native servis
        // zaten uygulama öldürüldüğünde alarmı durdurur.
        warningNotificationOnKill: false,
        volumeSettings: VolumeSettings.fade(
          volume: volume,
          fadeDuration: const Duration(seconds: 8),
          volumeEnforced: true,
        ),
        notificationSettings: NotificationSettings(
          title: title,
          body: body,
          stopButton: 'Durdur',
        ),
      ),
    );
  }

  /// Belirli bir alarmı (örn. kullanıcı uygulama içinden durdurduğunda) durdurur.
  static Future<void> stopRingingAlarm(int id) => Alarm.stop(id);

  /// Herhangi bir alarm şu an çalıyor mu?
  static Future<bool> isAnyAlarmRinging() => Alarm.isRinging();

  static Future<void> cancelAll() async {
    await _notificationsPlugin.cancelAll();
    await Alarm.stopAll();
  }

  static Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id: id);
  }
}
