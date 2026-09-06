import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/hive_service.dart';
import '../../../../core/services/background_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/utils/distance_calculator.dart';
import '../../../../core/utils/constants.dart';
import '../widgets/neon_button.dart';
import 'tracking_page.dart';

/// Debounce süresi: 350ms — kullanıcı yazmayı bıraktıktan sonra istek atılır.
const _kAutocompleteDebounceDuration = Duration(milliseconds: 350);

/// API zaman aşımı: 10 saniye.
const _kApiTimeout = Duration(seconds: 10);

/// Retry gecikmesi: 1.5 saniye — ağ hatalarında tek retry denemesi.
const _kRetryDelay = Duration(milliseconds: 1500);

class MapPage extends StatefulWidget {
  const MapPage({Key? key}) : super(key: key);

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  // Mapbox controller
  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointAnnotationManager;
  PointAnnotation? _currentMarker;

  // Varsayılan konum: İstanbul
  double _selectedLat = 41.0082;
  double _selectedLng = 28.9784;

  bool _isLoading = false;
  final TextEditingController _searchController = TextEditingController();

  // Search Box API — öneri listesi (suggest yanıtındaki suggestions dizisi)
  List<Map<String, dynamic>> _suggestions = [];
  Timer? _debounce;
  int _currentRequestTag = 0;

  // Search Box session token: aynı oturum boyunca sabit UUID.
  // Yeni oturum başladığında (clear veya sonuç seçilince) yenilenir.
  final _uuid = const Uuid();
  late String _sessionToken;

  // Önizleme mesafesi: hedef seçilince hesaplanır, takip başlamadan önce gösterilir.
  // null → henüz hesaplanmadı / hesaplanıyor  |  -1 → hata
  double? _previewDistanceMeters;
  bool _isCalculatingDistance = false;

  // Favori hedefler (ev/iş gibi) — hızlı seçim için.
  List<FavoriteDestination> _favorites = [];

  // Mapbox token (.env'den okunur)
  String get _mapboxToken => dotenv.env['MAPBOX_ACCESS_TOKEN'] ?? '';

  @override
  void initState() {
    super.initState();
    _sessionToken = _uuid.v4(); // İlk oturum token'ı
    // TextField değişince suffixIcon rebuild'i tetikle
    _searchController.addListener(() => setState(() {}));
    _loadFavorites();

    // Sayfa geçiş animasyonunun pürüzsüz tamamlanması için konum alma işlemini geciktiriyoruz.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        _determinePosition();
      }
    });
  }

  Future<void> _loadFavorites() async {
    final favorites = await HiveService.getFavorites();
    if (mounted) setState(() => _favorites = favorites);
  }

  Future<void> _selectFavorite(FavoriteDestination favorite) async {
    setState(() {
      _selectedLat = favorite.lat;
      _selectedLng = favorite.lng;
      _suggestions = [];
      _searchController.text = favorite.name;
      _previewDistanceMeters = null;
    });
    _mapboxMap?.flyTo(
      CameraOptions(center: Point(coordinates: Position(favorite.lng, favorite.lat)), zoom: 16.5),
      MapAnimationOptions(duration: 800),
    );
    await _updateMarker(favorite.lat, favorite.lng);
    await _updatePreviewDistance(favorite.lat, favorite.lng);
  }

  Future<void> _saveCurrentAsFavorite() async {
    final defaultName = _searchController.text.trim();
    if (defaultName.isEmpty) {
      _showErrorSnackBar('Önce haritadan veya aramadan bir hedef seçin.');
      return;
    }
    final controller = TextEditingController(text: defaultName);
    final String? name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Favorilere Ekle'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Örn: Ev, İş'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await HiveService.addFavorite(FavoriteDestination(name: name, lat: _selectedLat, lng: _selectedLng));
    await _loadFavorites();
    if (mounted) _showSuccessSnackBar('"$name" favorilere eklendi.');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────
  //  ÖNIZLEME MESAFESİ
  Future<void> _updatePreviewDistance(double destLat, double destLng) async {
    if (destLat == 0.0 && destLng == 0.0) return;

    setState(() {
      _isCalculatingDistance = true;
      _previewDistanceMeters = null;
    });

    try {
      final lastPos = await geo.Geolocator.getLastKnownPosition();
      if (lastPos != null) {
        final dist = DistanceCalculator.calculateDistance(lastPos.latitude, lastPos.longitude, destLat, destLng);
        if (mounted) setState(() { _previewDistanceMeters = dist; });
      }
    } catch (_) {}

    try {
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.high, timeLimit: Duration(seconds: 5)),
      );
      final double distanceM = DistanceCalculator.calculateDistance(position.latitude, position.longitude, destLat, destLng);
      if (mounted) setState(() { _previewDistanceMeters = distanceM; _isCalculatingDistance = false; });
    } on geo.PermissionDeniedException {
      if (mounted) setState(() { _previewDistanceMeters ??= -1; _isCalculatingDistance = false; });
    } catch (e) {
      if (mounted) setState(() { _isCalculatingDistance = false; _previewDistanceMeters ??= -1; });
    }
  }
  String _formatPreviewDistance(double? meters) {
    if (meters == null || meters < 0) return '';
    if (meters >= 1000) return '~${(meters / 1000).toStringAsFixed(1)} km';
    return '~${meters.toStringAsFixed(0)} m';
  }

  // ──────────────────────────────────────────────────────
  //  KONUM
  // ──────────────────────────────────────────────────────

  Future<void> _determinePosition() async {
    bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) _showErrorSnackBar('Konum servisi kapali.');
      return;
    }
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) return;
    }
    if (permission == geo.LocationPermission.deniedForever) return;

    try {
      final lastPosition = await geo.Geolocator.getLastKnownPosition();
      if (lastPosition != null && mounted) {
        setState(() { _selectedLat = lastPosition.latitude; _selectedLng = lastPosition.longitude; });
        _mapboxMap?.flyTo(CameraOptions(center: Point(coordinates: Position(_selectedLng, _selectedLat)), zoom: 15.0), MapAnimationOptions(duration: 500));
        _updateMarker(_selectedLat, _selectedLng);
      }
    } catch (e) {}

    try {
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
      );
      if (position.latitude == 0.0 && position.longitude == 0.0) return;
      if (mounted) {
        setState(() { _selectedLat = position.latitude; _selectedLng = position.longitude; });
        _mapboxMap?.flyTo(CameraOptions(center: Point(coordinates: Position(_selectedLng, _selectedLat)), zoom: 15.0), MapAnimationOptions(duration: 800));
        _updateMarker(_selectedLat, _selectedLng);
      }
    } catch (e) {}
  }
  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    // Ölçek çubuğu ve logo ayarlarını güncelle (saatle çakışmaması için)
    mapboxMap.scaleBar.updateSettings(
      ScaleBarSettings(
        enabled: true,
        position: OrnamentPosition.BOTTOM_RIGHT,
        marginBottom: 90,
        marginRight: 10,
      ),
    );

    mapboxMap.logo.updateSettings(
      LogoSettings(
        position: OrnamentPosition.BOTTOM_LEFT,
        marginBottom: 10,
        marginLeft: 10,
      ),
    );

    mapboxMap.attribution.updateSettings(
      AttributionSettings(
        position: OrnamentPosition.BOTTOM_LEFT,
        marginBottom: 10,
        marginLeft: 110, // Logo ile arası biraz daha açıldı
      ),
    );

    // PointAnnotationManager oluştur
    _pointAnnotationManager =
        await mapboxMap.annotations.createPointAnnotationManager();

    // Harita tıklama dinleyicisi (modern TapInteraction.onMap API)
    mapboxMap.addInteraction(
      TapInteraction.onMap((MapContentGestureContext context) {
        final lat = context.point.coordinates.lat.toDouble();
        final lng = context.point.coordinates.lng.toDouble();
        _onMapTapped(lat, lng);
      }),
    );

    // İlk marker'ı ekle
    await _updateMarker(_selectedLat, _selectedLng);
  }

  /// Turkuaz gradyanlı bir pin marker'ı programmatik olarak çizer (asset gerektirmez).
  Future<Uint8List> _buildMarkerImage() async {
    const double size = 80.0;
    const double r = 22.0;       // daire yarıçapı
    const double cx = size / 2;
    const double cy = size / 2 - 8;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));

    // Parlama gölgesi
    final glowPaint = Paint()
      ..color = const Color(0xFF00F2FE).withOpacity(0.40)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(const Offset(cx, cy + 2), r, glowPaint);

    // Gradyan dolgu (daire + üçgen kuyruk)
    final gradient = const LinearGradient(
      colors: [Color(0xFF4FACFE), Color(0xFF00F2FE)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Rect.fromLTWH(cx - r, cy - r, r * 2, r * 2));
    final fillPaint = Paint()..shader = gradient;

    canvas.drawCircle(const Offset(cx, cy), r, fillPaint);

    // Pin kuyruğu
    final tipPath = Path()
      ..moveTo(cx - 8, cy + r - 2)
      ..lineTo(cx + 8, cy + r - 2)
      ..lineTo(cx, cy + r + 16)
      ..close();
    canvas.drawPath(tipPath, fillPaint);

    // Beyaz kenarlık
    canvas.drawCircle(
      const Offset(cx, cy), r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // İç beyaz nokta
    canvas.drawCircle(const Offset(cx, cy), 7, Paint()..color = Colors.white);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Mevcut marker'ı siler ve yeni konuma programmatik pin marker ekler.
  static const String _kDestinationIconId = 'destination-marker-icon';

  Future<void> _updateMarker(double lat, double lng) async {
    if (_pointAnnotationManager == null) return;

    if (_currentMarker != null) {
      await _pointAnnotationManager!.delete(_currentMarker!);
      _currentMarker = null;
    }

    final markerBytes = await _buildMarkerImage();
    try {
      await _mapboxMap?.style.addStyleImage(
        _kDestinationIconId,
        1.0,
        MbxImage(width: 80, height: 80, data: markerBytes),
        false,
        [],
        [],
        null,
      );
    } catch (e) {
      debugPrint('[MapPage] Style image registration error: $e');
    }

    _currentMarker = await _pointAnnotationManager!.create(
      PointAnnotationOptions(
        geometry: Point(coordinates: Position(lng, lat)),
        iconImage: _kDestinationIconId,
        iconSize: 0.6,
      ),
    );
  }

  /// Haritaya tıklandığında çağrılır.
  void _onMapTapped(double lat, double lng) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    setState(() {
      _selectedLat = lat;
      _selectedLng = lng;
      _suggestions = [];
      _previewDistanceMeters = null; // Yeni hedef → eski mesafeyi sıfırla
      _searchController.text = 'Konum alınıyor...';
    });

    _updateMarker(lat, lng);
    _reverseGeocode(lat, lng);
    _updatePreviewDistance(lat, lng); // Tıklanan nokta için mesafe hesapla
  }

  // ──────────────────────────────────────────────────────
  //  ARAMA (MAPBOX SEARCH BOX API — suggest + retrieve)
  // ──────────────────────────────────────────────────────

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(_kAutocompleteDebounceDuration, () {
      if (query.isNotEmpty) {
        _fetchSuggestions(query);
      } else {
        // Input tamamen silindi → listeyi temizle ve yeni session başlat
        setState(() {
          _suggestions = [];
          _sessionToken = _uuid.v4();
        });
        debugPrint('[MapPage] Yeni arama oturumu başlatıldı: $_sessionToken');
      }
    });
  }

  /// Mapbox Search Box — Suggest endpoint.
  /// language=tr&country=TR + types=poi,address,place,neighborhood
  /// Session token aynı oturum boyunca sabit tutulur (faturalandırma optimizasyonu).
  Future<void> _fetchSuggestions(String input, {bool isRetry = false}) async {
    final int requestTag = ++_currentRequestTag;

    final Uri uri = Uri.https(
      'api.mapbox.com',
      '/search/searchbox/v1/suggest',
      {
        'q': input,
        'access_token': _mapboxToken,
        'session_token': _sessionToken,
        'language': 'tr',
        'country': 'TR',
        'types': 'poi,address,place,neighborhood',
        'limit': '10',
      },
    );

    try {
      final response = await http.get(uri).timeout(_kApiTimeout);

      if (requestTag != _currentRequestTag) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List rawList = data['suggestions'] as List? ?? [];

        setState(() {
          _suggestions =
              rawList.whereType<Map<String, dynamic>>().toList();
        });
        debugPrint('[MapPage] Search Box suggest: ${_suggestions.length} öneri');
      } else {
        debugPrint('[MapPage] Search Box suggest HTTP ${response.statusCode}');
        if (requestTag == _currentRequestTag) {
          _showErrorSnackBar('Arama servisi hatası: ${response.statusCode}');
        }
      }
    } on SocketException catch (e) {
      debugPrint('[MapPage] SocketException: $e');
      if (requestTag != _currentRequestTag) return;
      if (!isRetry) {
        await Future.delayed(_kRetryDelay);
        if (requestTag == _currentRequestTag) {
          debugPrint('[MapPage] Autocomplete retry deneniyor...');
          await _fetchSuggestions(input, isRetry: true);
        }
      } else {
        _showErrorSnackBar('Arama için internet bağlantısı kurulamadı.');
      }
    } on TimeoutException {
      debugPrint('[MapPage] TimeoutException — Search Box suggest');
      if (requestTag != _currentRequestTag) return;
      if (!isRetry) {
        await Future.delayed(_kRetryDelay);
        if (requestTag == _currentRequestTag) {
          debugPrint('[MapPage] Timeout sonrası retry deneniyor...');
          await _fetchSuggestions(input, isRetry: true);
        }
      } else {
        _showErrorSnackBar('Bağlantı zaman aşımına uğradı. İnternet bağlantınızı kontrol edin.');
      }
    } catch (e) {
      debugPrint('[MapPage] Suggestions Error: $e');
    }
  }

  /// Kullanıcı öneri listesinden bir öğe seçtiğinde çağrılır.
  /// Search Box Retrieve endpoint ile tam koordinat alınır.
  /// Aynı session_token kullanılır; retrieve sonrası yeni oturum başlatılır.
  Future<void> _selectSuggestion(Map<String, dynamic> suggestion) async {
    final String? mapboxId = suggestion['mapbox_id'] as String?;
    // Öneri metnini geçici olarak göster
    final String displayName = suggestion['name'] as String? ??
        suggestion['full_address'] as String? ??
        suggestion['place_formatted'] as String? ?? '';

    if (mapboxId == null || mapboxId.isEmpty) {
      debugPrint('[MapPage] mapbox_id boş — retrieve atlanamaz');
      return;
    }

    setState(() {
      _suggestions = [];
      _searchController.text = displayName;
      _isLoading = true;
    });

    debugPrint('[MapPage] Retrieve başlatılıyor: mapbox_id=$mapboxId session=$_sessionToken');

    final Uri uri = Uri.https(
      'api.mapbox.com',
      '/search/searchbox/v1/retrieve/$mapboxId',
      {
        'access_token': _mapboxToken,
        'session_token': _sessionToken,
      },
    );

    try {
      final response = await http.get(uri).timeout(_kApiTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List features = data['features'] as List? ?? [];

        if (features.isEmpty) {
          _showErrorSnackBar('Yer koordinatı alınamadı.');
          setState(() => _isLoading = false);
          return;
        }

        final feature = features[0] as Map<String, dynamic>;
        final coords =
            feature['geometry']?['coordinates'] as List? ?? [];

        if (coords.length < 2) {
          _showErrorSnackBar('Koordinat bilgisi eksik.');
          setState(() => _isLoading = false);
          return;
        }

        final double lng = (coords[0] as num).toDouble();
        final double lat = (coords[1] as num).toDouble();

        // Tam adresi properties'ten al (varsa)
        final props = feature['properties'] as Map<String, dynamic>? ?? {};
        final String fullAddress = props['full_address'] as String? ??
            props['name'] as String? ??
            displayName;

        setState(() {
          _selectedLat = lat;
          _selectedLng = lng;
          _searchController.text = fullAddress;
          _isLoading = false;
          _previewDistanceMeters = null; // Yeni hedef → eski mesafeyi sıfırla
          // Retrieve tamamlandı → yeni oturum başlat
          _sessionToken = _uuid.v4();
        });

        debugPrint('[MapPage] Retrieve tamamlandı: $fullAddress → lat=$lat, lng=$lng');
        debugPrint('[MapPage] Yeni session token: $_sessionToken');

        _mapboxMap?.flyTo(
          CameraOptions(
            center: Point(coordinates: Position(lng, lat)),
            zoom: 16.5,
          ),
          MapAnimationOptions(duration: 800),
        );

        await _updateMarker(lat, lng);

        // Retrieve bitti, koordinatlar güncellendi → mesafeyi hesapla
        await _updatePreviewDistance(lat, lng);
      } else {
        debugPrint('[MapPage] Retrieve HTTP ${response.statusCode}');
        _showErrorSnackBar('Yer detayları alınamadı: ${response.statusCode}');
        setState(() => _isLoading = false);
      }
    } on SocketException catch (e) {
      debugPrint('[MapPage] Retrieve SocketException: $e');
      if (mounted) {
        _showErrorSnackBar('Koordinat alınamadı. İnternet bağlantısı yok.');
        setState(() => _isLoading = false);
      }
    } on TimeoutException {
      debugPrint('[MapPage] Retrieve TimeoutException');
      if (mounted) {
        _showErrorSnackBar('Koordinat alınamadı. Zaman aşımı.');
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[MapPage] Retrieve Error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ──────────────────────────────────────────────────────
  //  REVERSE GEOCODING (Mapbox)
  // ──────────────────────────────────────────────────────

  Future<void> _reverseGeocode(double lat, double lng) async {
    debugPrint('[MapPage] Harita tıklaması: lat=$lat, lng=$lng');

    if (lat == 0.0 && lng == 0.0) {
      debugPrint('[MapPage] Uyarı: Null Island koordinatı seçildi!');
      if (mounted) setState(() => _searchController.text = 'Seçilen Nokta (0,0)');
      return;
    }

    final String url =
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$lng,$lat.json'
        '?access_token=$_mapboxToken'
        '&language=tr'
        '&limit=1';

    try {
      final response = await http.get(Uri.parse(url)).timeout(_kApiTimeout);
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List features = data['features'] as List? ?? [];

        if (features.isNotEmpty) {
          final address = features[0]['place_name'] as String? ??
              '(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)})';
          setState(() => _searchController.text = address);
          debugPrint('[MapPage] Reverse geocode sonucu: $address');
        } else {
          setState(() =>
              _searchController.text = '(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)})');
        }
      }
    } on SocketException {
      if (mounted) {
        setState(() =>
            _searchController.text = '(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)})');
        _showErrorSnackBar('Adres bilgisi alınamadı. İnternet bağlantısı yok.');
      }
    } on TimeoutException {
      if (mounted) {
        setState(() =>
            _searchController.text = '(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)})');
        _showErrorSnackBar('Adres bilgisi zaman aşımına uğradı.');
      }
    } catch (e) {
      debugPrint('[MapPage] Reverse Geocode Error: $e');
      if (mounted) {
        setState(() =>
            _searchController.text = '(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)})');
      }
    }
  }

  // ──────────────────────────────────────────────────────
  //  İNTERNET KONTROLÜ
  // ──────────────────────────────────────────────────────

  Future<bool> _hasActualInternet() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult.contains(ConnectivityResult.none)) return false;

      final String host = Uri.parse(MyBackgroundService.serverBaseUrl).host;
      final result = await InternetAddress.lookup(host.isEmpty ? 'mapbox.com' : host)
          .timeout(const Duration(seconds: 4));

      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      try {
        final result =
            await InternetAddress.lookup('mapbox.com').timeout(const Duration(seconds: 3));
        return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      } catch (__) {
        return false;
      }
    }
  }

  // ──────────────────────────────────────────────────────
  //  KONUM ONAYLAMA / TAKİP BAŞLATMA
  // ──────────────────────────────────────────────────────

  Future<void> _confirmLocation() async {
    setState(() => _isLoading = true);

    // Bildirim izni
    await NotificationService.requestPermissions();

    // Konum izni + platforma özgü arka plan takip güvencesi (iOS "Always",
    // Android pil optimizasyonu istisnası). Kullanıcı reddederse yine de
    // devam edilir; ancak arka plan takibi güvenilir çalışmayabilir.
    await _ensureReliableBackgroundTracking();

    final bool isOnline = await _hasActualInternet();
    final String destName = _searchController.text.isNotEmpty
        ? _searchController.text
        : 'Hedef Koordinat: (${_selectedLat.toStringAsFixed(4)}, ${_selectedLng.toStringAsFixed(4)})';

    if (isOnline) {
      final String deviceId = await HiveService.getOrCreateDeviceId();
      final AlarmThresholds thresholds = await HiveService.getThresholds();
      final Uri uri = Uri.parse('${MyBackgroundService.serverBaseUrl}/api/routes/');
      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        'ngrok-skip-browser-warning': 'true',
        'X-Device-Id': deviceId,
      };
      final String body = jsonEncode({
        'destination_name': destName,
        'dest_latitude': _selectedLat,
        'dest_longitude': _selectedLng,
        'threshold_far_m': thresholds.farM,
        'threshold_mid_m': thresholds.midM,
        'threshold_near_m': thresholds.nearM,
      });

      http.Response? response;
      try {
        response = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 8));
      } on TimeoutException {
        // SORUN 6 BENZERİ: Render'ın ücretsiz katmanı 15 dakika
        // hareketsizlikten sonra uyur; ilk istek 30-50sn sürebilir. Bunu
        // gerçek bir bağlantı hatası/"offline" sanıp kullanıcıya yanlışlıkla
        // "offline devam edilsin mi?" diye sormak yerine, sunucunun
        // uyandığını bildirip daha uzun bir zaman aşımıyla bir kez daha
        // deniyoruz (bkz. history_page.dart'taki aynı düzeltme).
        if (mounted) _showSuccessSnackBar('Sunucu uyanıyor, tekrar deneniyor...');
        try {
          response = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 45));
        } catch (e) {
          response = null;
        }
      } catch (e) {
        response = null;
      }

      if (response != null && response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final int routeId = data['id'];

        await HiveService.setTrackingState(
          routeId: routeId,
          name: destName,
          lat: _selectedLat,
          lng: _selectedLng,
        );

        await _startTracking();
      } else if (response != null) {
        _showErrorSnackBar('Backend sunucusu hata verdi. Durum: ${response.statusCode}');
        await _confirmOfflineFallback(destName, 'Sunucuya bağlanılamadı, offline devam edilsin mi?');
      } else {
        await _confirmOfflineFallback(destName, 'İşlem sırasında bir hata oluştu. Offline devam edilsin mi?');
      }
    } else {
      _showSuccessSnackBar('İnternet bulunamadı. Offline-First takip modu başlatıldı.');
      await _startOfflineTracking(destName);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  /// Platforma özgü, arka planda güvenilir konum takibi için gereken izin/ayar
  /// akışını yürütür. Her iki platformda da kullanıcı reddederse akış
  /// engellenmez; sadece takip arka planda düzensiz çalışabilir.
  Future<void> _ensureReliableBackgroundTracking() async {
    // Konum izni (When In Use / Always) — servis başlamadan önce alınmalı.
    geo.LocationPermission locPerm = await geo.Geolocator.checkPermission();
    if (locPerm == geo.LocationPermission.denied) {
      locPerm = await geo.Geolocator.requestPermission();
    }
    if (locPerm == geo.LocationPermission.deniedForever) return;

    if (Platform.isIOS) {
      // iOS'ta arka planda GPS almak için "Her Zaman İzin Ver" (Always) şart;
      // "Uygulamayı Kullanırken" (whileInUse) izni ekran kilitlenince veya
      // uygulama arka plana alınınca konum akışını durdurur. iOS bu izni
      // ikinci bir sistem isteğiyle (veya kullanıcı Ayarlar'dan) verir.
      final geo.LocationPermission refreshed = await geo.Geolocator.checkPermission();
      if (refreshed == geo.LocationPermission.whileInUse && mounted) {
        final bool? openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Arka Planda Takip İçin İzin Gerekli'),
            content: const Text(
              'WakeMeUp, ekranınız kilitliyken veya uygulama arka plandayken de '
              'hedefe yaklaştığınızı algılayabilmek için konum iznini "Her Zaman '
              'İzin Ver" olarak ayarlamanızı gerektirir. Aksi halde alarm yalnızca '
              'uygulama ekranda açıkken tetiklenir.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Şimdilik Devam Et'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Ayarları Aç'),
              ),
            ],
          ),
        );
        if (openSettings == true) {
          await geo.Geolocator.openAppSettings();
        }
      }
    } else if (Platform.isAndroid) {
      // Android'de üretici pil optimizasyonları (Xiaomi/Huawei/Samsung vb.)
      // foreground service'i yine de arka planda öldürebilir. Kullanıcıdan
      // uygulamayı optimizasyon istisnasına almasını istiyoruz.
      final ph.PermissionStatus batteryStatus =
          await ph.Permission.ignoreBatteryOptimizations.status;
      if (!batteryStatus.isGranted && mounted) {
        final bool? requestExemption = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Güvenilir Arka Plan Takibi'),
            content: const Text(
              'Telefonunuzun pil tasarrufu ayarları, ekran kapalıyken konum '
              'takibini durdurabilir. Alarmın güvenilir çalışması için WakeMeUp\'ı '
              'pil optimizasyonundan muaf tutmanızı öneririz.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Şimdilik Geç'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('İzin Ver'),
              ),
            ],
          ),
        );
        if (requestExemption == true) {
          await ph.Permission.ignoreBatteryOptimizations.request();
        }
      }

      // `alarm` paketinin STAGE_NEAR/varış anlarında gerçek çalar saat gibi
      // neredeyse anında tetiklenebilmesi için Android 12+ üzerinde gereken izin.
      try {
        final ph.PermissionStatus exactAlarmStatus =
            await ph.Permission.scheduleExactAlarm.status;
        if (!exactAlarmStatus.isGranted) {
          await ph.Permission.scheduleExactAlarm.request();
        }
      } catch (_) {
        // Bu izin tipini desteklemeyen OS sürümlerinde sessizce geç.
      }
    }
  }

  Future<void> _confirmOfflineFallback(String destName, String message) async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bağlantı Sorunu'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Offline Devam Et')),
        ],
      ),
    );
    if (proceed == true) await _startOfflineTracking(destName);
  }

  Future<void> _startOfflineTracking(String destName) async {
    await HiveService.setTrackingState(
      routeId: kOfflineRouteId,
      name: destName,
      lat: _selectedLat,
      lng: _selectedLng,
    );
    await _startTracking();
  }

  Future<void> _startTracking() async {
    final service = FlutterBackgroundService();
    final alreadyRunning = await service.isRunning();
    
    if (alreadyRunning) {
      // Temiz bellek ve yeni isolate dinleyicileri garanti etmek için mevcut servisi kapatıyoruz.
      debugPrint('[MapPage] Eski arka plan servisi kapatılıyor...');
      service.invoke('stopService');
      // Eski servisin durması ve OS'un kaynakları serbest bırakması için yeterli süre.
      await Future.delayed(const Duration(milliseconds: 600));
    }

    await service.startService();

    // SORUN 3 DÜZELTMESİ: 300ms → 800ms
    // Arka plan izolatının ayağa kalkıp tüm service.on(...).listen() çağrılarını
    // kaydetmesi için yeterli süre tanınıyor. Düşük sınıf cihazlarda 300ms yetersizdi.
    await Future.delayed(const Duration(milliseconds: 800));

    // Hive'dan onaylanan hedef bilgilerini oku.
    final routeId = await HiveService.getActiveRouteId() ?? kOfflineRouteId;
    final name = await HiveService.getDestName() ?? "Hedef";
    final lat = await HiveService.getDestLatitude() ?? 0.0;
    final lng = await HiveService.getDestLongitude() ?? 0.0;
    final deviceId = await HiveService.getOrCreateDeviceId();
    final thresholds = await HiveService.getThresholds();

    // Birincil mesaj: startTracking — ilk konum alımını ve tüm state'i initialize eder.
    service.invoke('startTracking', {
      'routeId': routeId,
      'name': name,
      'latitude': lat,
      'longitude': lng,
      'deviceId': deviceId,
      'thresholdFarM': thresholds.farM,
      'thresholdMidM': thresholds.midM,
      'thresholdNearM': thresholds.nearM,
    });

    // SORUN 3 EK GÜVENCESİ: startTracking kaybolursa diye 1s sonra bir de sync gönder.
    // sync listener mevcut GPS konumunu anında alıp UI'a iletir.
    Future.delayed(const Duration(milliseconds: 1000), () {
      service.invoke('sync', {
        'routeId': routeId,
        'name': name,
        'latitude': lat,
        'longitude': lng,
        'deviceId': deviceId,
        'thresholdFarM': thresholds.farM,
        'thresholdMidM': thresholds.midM,
        'thresholdNearM': thresholds.nearM,
      });
    });

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const TrackingPage()),
      );
    }
  }

  // ──────────────────────────────────────────────────────
  //  SNACKBAR YARDIMCILARI
  // ──────────────────────────────────────────────────────

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppColors.neonPink,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.teal,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ──────────────────────────────────────────────────────
  //  UI
  // ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Mapbox Harita ──────────────────────────────
          MapWidget(
            key: const ValueKey('mapbox_map'),
            styleUri: MapboxStyles.DARK,
            viewport: CameraViewportState(
              center: Point(
                coordinates: Position(_selectedLng, _selectedLat),
              ),
              zoom: 14.0,
            ),
            onMapCreated: _onMapCreated,
          ),

          // ── Sadece Geri Butonu (Header kaldırıldı) ─────
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 10,
            child: Container(
              decoration: BoxDecoration(
                color: theme.cardTheme.color?.withOpacity(0.7) ?? Colors.black54,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),

          // ── Arama + Öneri Paneli ───────────────────────
          Positioned(
            top: 80,
            left: 20,
            right: 20,
            child: SafeArea(
              child: Column(
                children: [
                  Card(
                    elevation: 10,
                    color: theme.cardTheme.color?.withOpacity(0.92),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: TextField(
                        controller: _searchController,
                        onChanged: _onSearchChanged,
                        decoration: InputDecoration(
                          hintText: 'Hedef adını girin (örn: Kadıköy)',
                          border: InputBorder.none,
                          icon: Icon(Icons.search, color: theme.colorScheme.primary),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    _searchController.clear();
                                    _onSearchChanged('');
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),

                  // Favori hedefler — sola kaydırarak gezilebilen hızlı seçim şeridi.
                  // İlk çip her zaman "Favori Ekle"dir; mevcut favoriler onun yanında sıralanır.
                  if (_suggestions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: SizedBox(
                        height: 34,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _favorites.length + 1,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return ActionChip(
                                avatar: const Icon(Icons.add_rounded, size: 16, color: AppColors.neonOrange),
                                label: const Text('Favori Ekle', style: TextStyle(fontSize: 12)),
                                backgroundColor: theme.cardTheme.color?.withOpacity(0.92),
                                side: BorderSide(color: AppColors.neonOrange.withOpacity(0.4)),
                                onPressed: _saveCurrentAsFavorite,
                              );
                            }
                            final favorite = _favorites[index - 1];
                            return ActionChip(
                              avatar: const Icon(Icons.star_rounded, size: 16, color: AppColors.neonOrange),
                              label: Text(favorite.name, style: const TextStyle(fontSize: 12)),
                              backgroundColor: theme.cardTheme.color?.withOpacity(0.92),
                              onPressed: () => _selectFavorite(favorite),
                            );
                          },
                        ),
                      ),
                    ),

                  // Öneri listesi
                  if (_suggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: theme.cardTheme.color?.withOpacity(0.98),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 10,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _suggestions.length,
                        separatorBuilder: (context, index) =>
                            Divider(color: Colors.white.withOpacity(0.1), height: 1),
                        itemBuilder: (context, index) {
                          final suggestion = _suggestions[index];
                          // Search Box suggest yanıtı: name, place_formatted, maki (ikon tipi)
                          final String mainText =
                              suggestion['name'] as String? ?? '';
                          final String secondary =
                              suggestion['place_formatted'] as String? ??
                              suggestion['full_address'] as String? ?? '';
                          // POI türüne göre ikon seç
                          final String? featureType =
                              (suggestion['feature_type'] as String?)?.toLowerCase();
                          final IconData locationIcon = featureType == 'poi'
                              ? Icons.store_outlined
                              : featureType == 'address'
                                  ? Icons.home_outlined
                                  : Icons.location_on_outlined;

                          return ListTile(
                            leading: Icon(
                              locationIcon,
                              color: theme.colorScheme.primary.withOpacity(0.7),
                            ),
                            title: Text(
                              mainText,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            subtitle: Text(
                              secondary,
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectSuggestion(suggestion),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── Alt Onay Paneli ────────────────────────────
          Positioned(
            bottom: 60,
            left: 20,
            right: 20,
            child: Card(
              color: theme.cardTheme.color?.withOpacity(0.95),
              elevation: 12,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.neonBlue.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.location_on,
                              color: AppColors.neonBlue, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Varış Noktası',
                                style: TextStyle(
                                    color: AppColors.textMuted, fontSize: 12),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _searchController.text.isNotEmpty
                                    ? _searchController.text
                                    : 'Harita Üzerinde Seçilen Nokta',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            tooltip: 'Favorilere Ekle',
                            icon: const Icon(Icons.star_border_rounded, color: AppColors.neonOrange),
                            onPressed: _saveCurrentAsFavorite,
                          ),
                      ],
                    ),

                    // ── Önizleme mesafesi chip ──────────────
                    if (_isCalculatingDistance || _previewDistanceMeters != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: (_previewDistanceMeters != null &&
                                        _previewDistanceMeters! >= 0)
                                    ? AppColors.neonBlue.withValues(alpha: 0.12)
                                    : AppColors.neonPink.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: (_previewDistanceMeters != null &&
                                          _previewDistanceMeters! >= 0)
                                      ? AppColors.neonBlue.withValues(alpha: 0.5)
                                      : AppColors.neonPink.withValues(alpha: 0.5),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isCalculatingDistance)
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor: AlwaysStoppedAnimation(
                                            AppColors.neonBlue),
                                      ),
                                    )
                                  else
                                    Icon(
                                      _previewDistanceMeters! >= 0
                                          ? Icons.straighten
                                          : Icons.warning_amber_rounded,
                                      size: 13,
                                      color: _previewDistanceMeters! >= 0
                                          ? AppColors.neonBlue
                                          : AppColors.neonPink,
                                    ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      _isCalculatingDistance
                                          ? 'Mesafe hesaplanıyor...'
                                          : _previewDistanceMeters! >= 0
                                              ? 'Kuş uçuşu ${_formatPreviewDistance(_previewDistanceMeters)}'
                                              : 'Mesafe alınamadı',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _isCalculatingDistance ||
                                                _previewDistanceMeters! >= 0
                                            ? AppColors.neonBlue
                                            : AppColors.neonPink,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 20),
                    _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : NeonButton(
                            text: 'Konumu Onayla ve Başlat',
                            onTap: _confirmLocation,
                          ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


