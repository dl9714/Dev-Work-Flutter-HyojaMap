import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';

const String appTitle = '효자 지도맵';
const String appVersion = '2026-08-25.3';
const String androidApplicationId = 'com.raccoonsom.hyojamap';

void main() {
  assert(() {
    debugPrint('$appTitle developer version: $appVersion');
    return true;
  }());
  runApp(const GrandparentsMapApp());
}

class GrandparentsMapApp extends StatelessWidget {
  const GrandparentsMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      theme: ThemeData(
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        useMaterial3: true,
        textTheme: const TextTheme(
          displayLarge: TextStyle(
              fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black87),
          titleLarge: TextStyle(
              fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87),
          bodyLarge: TextStyle(fontSize: 20, color: Colors.black87),
        ),
      ),
      home: const GalleryHomeScreen(),
    );
  }
}

class SafetySettingsData {
  final String homeAddress;

  const SafetySettingsData({
    required this.homeAddress,
  });
}

class SafetyUtils {
  static const String homeAddressPreferenceKey = 'home_address';
  static const String reverseAddressCachePreferenceKey =
      'reverse_address_cache';
  static const String reverseGeocodingHost = 'nominatim.openstreetmap.org';
  static DateTime? _lastReverseGeocodingRequestAt;

  static Future<SafetySettingsData> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return SafetySettingsData(
      homeAddress: prefs.getString(homeAddressPreferenceKey) ?? '',
    );
  }

  static Future<void> saveSettings({
    required String homeAddress,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(homeAddressPreferenceKey, homeAddress.trim());
  }

  static String addressFromPlacemark(Placemark placemark) {
    final parts = <String?>[
      placemark.administrativeArea,
      placemark.locality,
      placemark.subLocality,
      placemark.thoroughfare,
      placemark.subThoroughfare,
    ];
    final unique = <String>[];
    for (final part in parts) {
      final value = (part ?? '').trim();
      if (value.isNotEmpty && !unique.contains(value)) unique.add(value);
    }
    return unique.join(' ');
  }

  static Uri buildReverseGeocodingUri(double latitude, double longitude) {
    return Uri.https(reverseGeocodingHost, '/reverse', {
      'format': 'jsonv2',
      'lat': latitude.toString(),
      'lon': longitude.toString(),
      'zoom': '18',
      'addressdetails': '1',
      'accept-language': 'ko',
      'layer': 'address',
    });
  }

  static String addressFromNominatimData(Map<String, dynamic> data) {
    final addressData = data['address'];
    if (addressData is Map) {
      final parts = <dynamic>[
        addressData['state'],
        addressData['city'],
        addressData['county'],
        addressData['borough'],
        addressData['town'],
        addressData['village'],
        addressData['suburb'],
        addressData['neighbourhood'],
        addressData['road'],
        addressData['house_number'],
      ];
      final unique = <String>[];
      for (final part in parts) {
        final value = (part ?? '').toString().trim();
        if (value.isNotEmpty && !unique.contains(value)) unique.add(value);
      }
      if (unique.isNotEmpty) return unique.join(' ');
    }

    final displayName = (data['display_name'] ?? '').toString().trim();
    return displayName
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != '대한민국')
        .join(' ');
  }

  static String _coordinateCacheKey(double latitude, double longitude) {
    return '${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}';
  }

  static Future<String> _loadCachedAddress(
    double latitude,
    double longitude,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final rawCache = prefs.getString(reverseAddressCachePreferenceKey);
    if (rawCache == null || rawCache.isEmpty) return '';
    try {
      final cache = jsonDecode(rawCache);
      if (cache is! Map) return '';
      return (cache[_coordinateCacheKey(latitude, longitude)] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static Future<void> _saveCachedAddress(
    double latitude,
    double longitude,
    String address,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final rawCache = prefs.getString(reverseAddressCachePreferenceKey);
    final cache = <String, dynamic>{};
    if (rawCache != null && rawCache.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCache);
        if (decoded is Map) {
          cache.addAll(decoded.map((key, value) => MapEntry('$key', value)));
        }
      } catch (_) {
        // 손상된 캐시는 버리고 새로 저장합니다.
      }
    }
    cache[_coordinateCacheKey(latitude, longitude)] = address;
    while (cache.length > 40) {
      cache.remove(cache.keys.first);
    }
    await prefs.setString(reverseAddressCachePreferenceKey, jsonEncode(cache));
  }

  static Future<String> resolveCurrentAddress(
    double latitude,
    double longitude,
  ) async {
    final cachedAddress = await _loadCachedAddress(latitude, longitude);
    if (cachedAddress.isNotEmpty) return cachedAddress;

    try {
      final placemarks = await placemarkFromCoordinates(latitude, longitude);
      if (placemarks.isNotEmpty) {
        final address = addressFromPlacemark(placemarks.first);
        if (address.isNotEmpty) {
          await _saveCachedAddress(latitude, longitude, address);
          return address;
        }
      }
    } catch (e) {
      debugPrint('Device reverse geocoding error: $e');
    }

    try {
      final previousRequestAt = _lastReverseGeocodingRequestAt;
      if (previousRequestAt != null) {
        final waitTime = const Duration(seconds: 1) -
            DateTime.now().difference(previousRequestAt);
        if (!waitTime.isNegative) await Future<void>.delayed(waitTime);
      }
      _lastReverseGeocodingRequestAt = DateTime.now();

      final headers = <String, String>{'Accept': 'application/json'};
      if (!kIsWeb) {
        headers['User-Agent'] =
            'HyojaMap/1.0.1 (+https://github.com/dl9714/Dev-Work-Flutter-HyojaMap)';
      }
      final response = await http
          .get(
            buildReverseGeocodingUri(latitude, longitude),
            headers: headers,
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return '';

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return '';
      final address = addressFromNominatimData(decoded);
      if (address.isNotEmpty) {
        await _saveCachedAddress(latitude, longitude, address);
      }
      return address;
    } catch (e) {
      debugPrint('Online reverse geocoding error: $e');
      return '';
    }
  }
}

Future<void> showHomeAddressSettingsDialog(BuildContext context) async {
  final settings = await SafetyUtils.loadSettings();
  if (!context.mounted) return;

  var homeAddress = settings.homeAddress;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Text('집 주소 설정'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '집으로 가기에 사용할 주소를 등록해 주세요.',
              style: TextStyle(color: Colors.black54, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('home-address-field'),
              initialValue: homeAddress,
              onChanged: (value) => homeAddress = value,
              keyboardType: TextInputType.streetAddress,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '집 주소',
                hintText: '집으로 가기에 사용할 주소',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () async {
            await SafetyUtils.saveSettings(
              homeAddress: homeAddress,
            );
            if (dialogContext.mounted) Navigator.pop(dialogContext, true);
          },
          style: FilledButton.styleFrom(backgroundColor: Colors.teal),
          child: const Text('저장'),
        ),
      ],
    ),
  );

  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('집 주소를 저장했습니다.')),
    );
  }
}

class CurrentLocationScreen extends StatefulWidget {
  const CurrentLocationScreen({super.key});

  @override
  State<CurrentLocationScreen> createState() => _CurrentLocationScreenState();
}

class _CurrentLocationScreenState extends State<CurrentLocationScreen> {
  bool _isLoading = true;
  Position? _position;
  String _address = '';
  String _homeAddress = '';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSafetyInformation();
  }

  Future<void> _loadSafetyInformation() async {
    final settings = await SafetyUtils.loadSettings();
    final position = await MapActionUtils.getCurrentPosition().timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
    var address = '';
    String? errorMessage;

    if (position == null) {
      errorMessage = '현재 위치를 확인할 수 없습니다. 위치 기능과 권한을 켜 주세요.';
    } else {
      address = await SafetyUtils.resolveCurrentAddress(
        position.latitude,
        position.longitude,
      );
      if (address.isEmpty) {
        errorMessage = '현재 주소를 불러오지 못했습니다. 잠시 후 다시 확인해 주세요.';
      }
    }

    if (!mounted) return;
    setState(() {
      _position = position;
      _address = address;
      _homeAddress = settings.homeAddress;
      _errorMessage = errorMessage;
      _isLoading = false;
    });
  }

  Future<void> _retryLocation() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    await _loadSafetyInformation();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _goHome() async {
    if (_homeAddress.isEmpty) {
      _showMessage('관리자 모드의 집 주소 설정에서 주소를 등록해 주세요.');
      return;
    }
    await MapActionUtils(context, 'images_hospital').launchMapAction({
      'dName': _homeAddress,
      'sName': '',
    });
  }

  Widget _largeActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 30),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('현재 위치 보기', maxLines: 1),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('현재 위치를 확인하고 있습니다...'),
                ],
              ),
            )
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5F2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.my_location,
                            size: 48, color: Colors.teal),
                        const SizedBox(height: 10),
                        const Text(
                          '현재 위치',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _errorMessage ?? _address,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.bold,
                            height: 1.4,
                          ),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _retryLocation,
                            icon: const Icon(Icons.refresh),
                            label: const Text('위치 다시 확인'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_position case final position?) ...[
                    const Padding(
                      padding: EdgeInsets.only(left: 2, bottom: 10),
                      child: Text(
                        '현재 위치 지도',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    CurrentLocationMap(
                      latitude: position.latitude,
                      longitude: position.longitude,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '지도를 손가락으로 움직이거나 확대할 수 있습니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54, height: 1.4),
                    ),
                    const SizedBox(height: 18),
                  ],
                  _largeActionButton(
                    icon: Icons.home,
                    label: '집으로 가기',
                    color: Colors.blueGrey.shade700,
                    onPressed: _goHome,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
    );
  }
}

class CurrentLocationMap extends StatelessWidget {
  final double latitude;
  final double longitude;

  const CurrentLocationMap({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  @override
  Widget build(BuildContext context) {
    final center = LatLng(latitude, longitude);
    return ClipRRect(
      key: const ValueKey('current-location-map'),
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 320,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: 17,
            minZoom: 5,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: androidApplicationId,
              maxNativeZoom: 19,
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: center,
                  width: 64,
                  height: 64,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.teal, width: 4),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.my_location,
                      color: Colors.teal,
                      size: 34,
                    ),
                  ),
                ),
              ],
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                  'OpenStreetMap contributors',
                  onTap: () {
                    launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------
// 메인 갤러리 화면 (폴더 선택 + 관리자 모드 진입)
// ----------------------------------------------------

class GalleryHomeScreen extends StatefulWidget {
  const GalleryHomeScreen({super.key});

  @override
  State<GalleryHomeScreen> createState() => _GalleryHomeScreenState();
}

class _GalleryHomeScreenState extends State<GalleryHomeScreen> {
  // 관리자 모드 여부
  bool _isAdminMode = false;

  // 관리자 비밀번호 (일단 '0000'으로 고정)
  final String _adminPassword = '0000';

  void _toggleAdminMode() async {
    if (_isAdminMode) {
      // 이미 관리자 모드면 끄기
      setState(() {
        _isAdminMode = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('관리자 모드가 해제되었습니다.')),
      );
    } else {
      // 관리자 모드 켜기 -> 비밀번호 확인
      await _showPasswordDialog();
    }
  }

  Future<void> _showPasswordDialog() async {
    final TextEditingController passwordController = TextEditingController();

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          title: const Text('관리자 확인'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                const Text('사진과 길찾기 정보를 바꾸려면 비밀번호를 입력하세요.'),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.teal, size: 22),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '자녀가 변경해 주세요',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 6),
                      Text(
                        '휴대폰을 누르다가 사진이나 길찾기 정보가 실수로 바뀌거나 삭제되는 것을 막기 위한 보호 기능입니다.',
                        style: TextStyle(fontSize: 14, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '관리자 비밀번호: 0000 (항상 동일)',
                  style: TextStyle(color: Colors.black54, fontSize: 14),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passwordController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '비밀번호',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('취소'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            ElevatedButton(
              child: const Text('확인'),
              onPressed: () {
                if (passwordController.text == _adminPassword) {
                  setState(() {
                    _isAdminMode = true;
                  });
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('관리자 모드로 전환되었습니다.')),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('비밀번호가 틀렸습니다.')),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNarrowScreen = MediaQuery.sizeOf(context).width < 360;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 82,
        leading: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: TextButton(
            key: const ValueKey('current-location-appbar-button'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CurrentLocationScreen(),
                ),
              );
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.teal,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.my_location, size: 26),
                SizedBox(height: 1),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '현재 위치',
                    maxLines: 1,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
        titleSpacing: 0,
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                appTitle,
                maxLines: 1,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        centerTitle: true,
        toolbarHeight: 72,
        actions: [
          // 관리자 모드 토글 버튼
          IconButton(
            icon: Icon(
              _isAdminMode ? Icons.lock_open : Icons.lock,
              color: _isAdminMode ? Colors.teal : Colors.grey,
              size: 32,
            ),
            onPressed: _toggleAdminMode,
            tooltip: _isAdminMode ? '관리자 모드 끄기' : '관리자 모드 켜기',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(isNarrowScreen ? 14 : 20),
        children: [
          if (_isAdminMode)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.verified_user_outlined,
                          color: Colors.teal, size: 28),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: double.infinity,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '관리자 모드',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 2),
                            SizedBox(
                              width: double.infinity,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '사진 · 경로 · 집 주소 관리',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () =>
                              showHomeAddressSettingsDialog(context),
                          icon: const Icon(Icons.home_outlined, size: 20),
                          label: const Text('집 주소'),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.teal),
                        ),
                        TextButton.icon(
                          onPressed: () => showMapAppSettingsDialog(context),
                          icon: const Icon(Icons.map_outlined, size: 20),
                          label: const Text('지도 설정'),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.teal),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // 1번 폴더: 현재위치에서 목적지 가는 길 (출발지 = 현재위치 고정)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 170),
            child: _buildBigFolderCard(
              context,
              title: '현재위치에서 목적지 가는 길',
              icon: Icons.navigation,
              color: Colors.green.shade100,
              iconColor: Colors.green.shade800,
              page: DetailGalleryPage(
                storageKey: 'images_hospital',
                title: '현재위치에서 목적지 가는 길',
                description: '지금 계신 곳에서\n목적지까지 가는 방법입니다.',
                isAdminMode: _isAdminMode,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 2번 폴더: 버스 경로 + 집 to 전철역 (경로 찾기 - 출발지/목적지 모두 입력)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 170),
            child: _buildBigFolderCard(
              context,
              title: '버스 및 전철 가는 길',
              icon: Icons.directions_bus,
              color: Colors.blue.shade100,
              iconColor: Colors.blue.shade800,
              page: DetailGalleryPage(
                storageKey: 'images_transport', // 저장소 키 (경로 찾기)
                title: '버스 및 전철 가는 길',
                description: '버스 노선도와\n전철역까지 가는 방법입니다.',
                isAdminMode: _isAdminMode,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3번 폴더: 집 주변 지도 (장소 검색)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 170),
            child: _buildBigFolderCard(
              context,
              title: '집 주변 지도',
              icon: Icons.map,
              color: Colors.orange.shade100,
              iconColor: Colors.deepOrange,
              page: DetailGalleryPage(
                storageKey: 'images_map',
                title: '집 주변 지도',
                description: '집 근처의 약도와\n중요한 장소들입니다.',
                isAdminMode: _isAdminMode,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildBigFolderCard(BuildContext context,
      {required String title,
      required IconData icon,
      required Color color,
      required Color iconColor,
      required Widget page}) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => page),
        );
      },
      child: Container(
        key: ValueKey('folder-card-$title'),
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 170),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withValues(alpha: 0.3),
              spreadRadius: 2,
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: iconColor),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  title,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(30),
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '터치하여 보기',
                  maxLines: 1,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------
// 믹스인 및 유틸리티 클래스 (수정된 버전)
// ----------------------------------------------------

mixin AdminDialogsMixin<T extends StatefulWidget> on State<T> {
  // Mixin에서 필요한 상태 변수 정의 (DetailGalleryPage에서 정의됨)
  abstract String _currentDescription;
  abstract List<Map<String, dynamic>> _routes;

  // Mixin에서 필요한 메서드 정의 (DetailGalleryPage에서 정의됨)
  Future<void> _saveDescription(String newDescription);
  Future<void> _saveRoutes();

  // [1] 장소/경로 추가 또는 수정 다이얼로그
  Future<void> _addOrEditRouteDialog({int? index}) async {
    final state = this as _DetailGalleryPageState; // 캐스팅

    // 모드 확인
    bool isCurrentToDest =
        state.widget.storageKey == 'images_hospital'; // 현재위치->목적지 모드
    bool isTransport =
        state.widget.storageKey == 'images_transport'; // 버스/전철 모드
    bool isRouteMode = isCurrentToDest || isTransport;

    Map<String, dynamic> initialData = index != null
        ? _routes[index]
        : (isRouteMode
            ? {'name': '', 'sName': '', 'dName': ''}
            : {'name': '', 'location': ''});

    final nameController = TextEditingController(text: initialData['name']);
    final sNameController = TextEditingController(text: initialData['sName']);
    final dNameController = TextEditingController(text: initialData['dName']);
    final locationController =
        TextEditingController(text: initialData['location']);

    await showDialog(
      context: state.context,
      builder: (context) {
        return AlertDialog(
          title: Text(index == null ? '새 항목 추가' : '항목 수정'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                        labelText: '버튼 이름 (예: 복지관 가는 길)')),
                const SizedBox(height: 10),

                // 경로 모드일 때
                if (isRouteMode) ...[
                  // 버스/전철일 때만 출발지 입력을 받습니다.
                  if (isTransport)
                    TextField(
                        controller: sNameController,
                        decoration: const InputDecoration(
                            labelText: '출발지 주소 (예: 우리집)')),

                  TextField(
                      controller: dNameController,
                      decoration: const InputDecoration(
                          labelText: '도착지 주소 (예: 시청, 서울역)')),

                  // 현재위치->목적지 모드일 때 안내 문구
                  if (isCurrentToDest)
                    const Padding(
                      padding: EdgeInsets.only(top: 15.0),
                      child: Text("※ '현재 위치'에서 출발하는 경로입니다.\n도착지만 입력하면 됩니다.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.blue, fontWeight: FontWeight.bold)),
                    ),
                ] else ...[
                  // 일반 장소 검색 모드 (집 주변 지도)
                  TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                          labelText: '장소 주소 (예: 동네마트 주소)')),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소')),
            ElevatedButton(
                onPressed: () {
                  state.setState(() {
                    Map<String, dynamic> data;

                    if (isRouteMode) {
                      data = {
                        'name': nameController.text,
                        // 현재위치 모드이면 출발지('')로 비워서 저장
                        'sName': isCurrentToDest ? '' : sNameController.text,
                        'dName': dNameController.text
                      };
                    } else {
                      data = {
                        'name': nameController.text,
                        'location': locationController.text
                      };
                    }

                    if (index == null) {
                      _routes.add(data);
                    } else {
                      _routes[index] = data;
                    }
                  });
                  _saveRoutes();
                  Navigator.pop(context);
                },
                child: const Text('저장')),
          ],
        );
      },
    );
  }

  // [2] 설명 수정 다이얼로그
  Future<void> _editDescriptionDialog() async {
    final state = this as _DetailGalleryPageState;
    final TextEditingController controller =
        TextEditingController(text: _currentDescription);
    await showDialog(
      context: state.context,
      builder: (context) {
        return AlertDialog(
          title: const Text('설명 수정'),
          content: TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(border: OutlineInputBorder())),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소')),
            ElevatedButton(
                onPressed: () {
                  _saveDescription(controller.text);
                  Navigator.pop(context);
                },
                child: const Text('저장')),
          ],
        );
      },
    );
  }
}

mixin DataManagementMixin<T extends StatefulWidget> on State<T> {
  // DetailGalleryPage의 상태와 연결되어야 하는 변수들
  abstract List<String> _imagePaths;
  abstract String _currentDescription;
  abstract List<Map<String, dynamic>> _routes;
  abstract bool _isLoading;
  final ImagePicker _picker = ImagePicker();

  // DetailGalleryPage의 위젯 프로퍼티 접근을 위한 추상 getter
  String get storageKey;
  String get description;

  // 데이터 로드
  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _imagePaths = prefs.getStringList(storageKey) ?? [];
      _currentDescription =
          prefs.getString('${storageKey}_desc') ?? description;

      String? routesJson = prefs.getString('${storageKey}_routes');
      if (routesJson != null) {
        _routes = List<Map<String, dynamic>>.from(jsonDecode(routesJson));
      }
      _isLoading = false;
    });
  }

  // 이미지 경로 저장
  Future<void> _saveImages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(storageKey, _imagePaths);
  }

  // 설명 저장
  Future<void> _saveDescription(String newDescription) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${storageKey}_desc', newDescription);
    setState(() {
      _currentDescription = newDescription;
    });
  }

  // 경로 저장
  Future<void> _saveRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${storageKey}_routes', jsonEncode(_routes));
  }

  // 이미지 추가
  Future<void> _addImage() async {
    try {
      final XFile? pickedFile =
          await _picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null) {
        final directory = await getApplicationDocumentsDirectory();
        final String savedPath =
            path.join(directory.path, path.basename(pickedFile.path));
        await File(pickedFile.path).copy(savedPath);
        setState(() {
          _imagePaths.add(savedPath);
        });
        await _saveImages();
      }
    } catch (e) {
      // 오류 처리
    }
  }

  // 이미지 삭제
  Future<void> _deleteImage(int index) async {
    setState(() {
      _imagePaths.removeAt(index);
    });
    await _saveImages();
  }

  // 경로/장소 삭제
  Future<void> _deleteRoute(int index) async {
    setState(() {
      _routes.removeAt(index);
    });
    _saveRoutes();
  }
}

class MapActionUtils {
  final BuildContext context;
  final String storageKey;

  MapActionUtils(this.context, this.storageKey);

  // 지도 타입 정의
  static const String TYPE_NAVER = 'naver';
  static const String TYPE_KAKAO = 'kakao';
  static const String TYPE_TMAP = 'tmap';
  static const String TYPE_GOOGLE = 'google';
  static const String TYPE_WEB = 'web';

  static const String selectedProviderPreferenceKey = 'selected_map_provider';
  static const String _legacyPriorityPreferenceKey = 'map_priority';
  static const String _legacyEnabledPreferenceKey = 'map_enabled';

  static const List<String> supportedProviders = [
    TYPE_NAVER,
    TYPE_KAKAO,
    TYPE_TMAP,
    TYPE_GOOGLE,
    TYPE_WEB
  ];

  static String normalizeSelectedProvider(String? provider) {
    return supportedProviders.contains(provider) ? provider! : TYPE_NAVER;
  }

  static Future<String> loadSelectedProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(selectedProviderPreferenceKey);
    if (saved != null) return normalizeSelectedProvider(saved);

    // 이전 버전의 순서/켜기 설정은 한 번만 단일 선택값으로 옮깁니다.
    final legacyOrder =
        prefs.getStringList(_legacyPriorityPreferenceKey) ?? supportedProviders;
    final legacyEnabled =
        prefs.getStringList(_legacyEnabledPreferenceKey)?.toSet();
    final migrated = legacyOrder.firstWhere(
      (type) =>
          supportedProviders.contains(type) &&
          (legacyEnabled == null || legacyEnabled.contains(type)),
      orElse: () => TYPE_NAVER,
    );
    await prefs.setString(selectedProviderPreferenceKey, migrated);
    return migrated;
  }

  static Future<void> saveSelectedProvider(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      selectedProviderPreferenceKey,
      normalizeSelectedProvider(provider),
    );
  }

  static String resolveProviderForAction(
    String selectedProvider,
    String storageKey, {
    required bool hasStartCoordinates,
    required bool hasDestinationCoordinates,
  }) {
    final selected = normalizeSelectedProvider(selectedProvider);
    final isTransport = storageKey == 'images_transport';
    final isCurrentToDestination = storageKey == 'images_hospital';
    final isRoute = isTransport || isCurrentToDestination;

    // TMAP 공개 앱 연동은 목적지 자동차 길안내용입니다. 대중교통의
    // 지정 출발지/도착지를 잃지 않도록 이 경우에는 인터넷 지도를 엽니다.
    if (selected == TYPE_TMAP && isTransport) return TYPE_WEB;

    if (isRoute &&
        {TYPE_NAVER, TYPE_KAKAO, TYPE_TMAP}.contains(selected) &&
        !hasDestinationCoordinates) {
      return TYPE_WEB;
    }

    // 네이버/카카오의 지정 출발지 경로는 좌표가 있어야 정확히 전달됩니다.
    if (isTransport &&
        {TYPE_NAVER, TYPE_KAKAO}.contains(selected) &&
        !hasStartCoordinates) {
      return TYPE_WEB;
    }

    // 카카오는 현재 위치 생략 동작을 공식 문서가 보장하지 않으므로
    // 앱에서 얻은 현재 위치 좌표가 없으면 안전한 웹 길찾기를 사용합니다.
    if (isCurrentToDestination &&
        selected == TYPE_KAKAO &&
        !hasStartCoordinates) {
      return TYPE_WEB;
    }

    return selected;
  }

  Future<bool> _launchUrlSafe(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Launch Error: $e');
      return false;
    }
  }

  // URL 생성 도우미 (타입별 URL 반환)
  static Uri? generateUrl(
      String type,
      bool isRouteMode,
      String? sName,
      double? sLat,
      double? sLng,
      String? dName,
      double? dLat,
      double? dLng,
      String? location) {
    final destName = isRouteMode ? (dName ?? '') : (location ?? '');
    final hasStartCoordinates = sLat != null && sLng != null;
    final hasDestinationCoordinates = dLat != null && dLng != null;

    switch (type) {
      case TYPE_NAVER:
        if (isRouteMode) {
          if (!hasDestinationCoordinates) return null;
          return Uri(
            scheme: 'nmap',
            host: 'route',
            path: '/public',
            queryParameters: {
              if (hasStartCoordinates) 'slat': '$sLat',
              if (hasStartCoordinates) 'slng': '$sLng',
              if (hasStartCoordinates) 'sname': sName ?? '현재 위치',
              'dlat': '$dLat',
              'dlng': '$dLng',
              if ((dName ?? '').isNotEmpty) 'dname': dName,
              'appname': androidApplicationId,
            },
          );
        } else {
          return Uri(
            scheme: 'nmap',
            host: 'search',
            queryParameters: {
              'query': location ?? '',
              'appname': androidApplicationId,
            },
          );
        }

      case TYPE_KAKAO:
        if (isRouteMode) {
          if (!hasStartCoordinates || !hasDestinationCoordinates) return null;
          return Uri(
            scheme: 'kakaomap',
            host: 'route',
            queryParameters: {
              'sp': '$sLat,$sLng',
              'ep': '$dLat,$dLng',
              'by': 'publictransit',
            },
          );
        } else {
          return Uri(
            scheme: 'kakaomap',
            host: 'search',
            queryParameters: {'q': location ?? ''},
          );
        }

      case TYPE_TMAP:
        if (isRouteMode) {
          if (!hasDestinationCoordinates) return null;
          return Uri(
            scheme: 'tmap',
            host: 'route',
            queryParameters: {
              'goalname': destName,
              'goalx': '$dLng',
              'goaly': '$dLat',
            },
          );
        }
        return Uri(
          scheme: 'tmap',
          host: 'search',
          queryParameters: {'name': destName},
        );

      case TYPE_GOOGLE:
      case TYPE_WEB:
        if (isRouteMode) {
          return Uri.https('www.google.com', '/maps/dir/', {
            'api': '1',
            if (hasStartCoordinates) 'origin': '$sLat,$sLng',
            if (!hasStartCoordinates && (sName ?? '').isNotEmpty)
              'origin': sName,
            'destination':
                hasDestinationCoordinates ? '$dLat,$dLng' : (dName ?? ''),
            'travelmode': 'transit',
          });
        } else {
          return Uri.https('www.google.com', '/maps/search/', {
            'api': '1',
            'query': location ?? '',
          });
        }

      default:
        return null;
    }
  }

  static Future<Position?> getCurrentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (e) {
      debugPrint('Current location error: $e');
      return null;
    }
  }

  static String providerName(String type) {
    switch (type) {
      case TYPE_NAVER:
        return '네이버 지도';
      case TYPE_KAKAO:
        return '카카오맵';
      case TYPE_TMAP:
        return '티맵';
      case TYPE_GOOGLE:
        return '구글 지도';
      case TYPE_WEB:
        return '인터넷 지도';
      default:
        return '지도';
    }
  }

  void _showMessage(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // 메인 실행 함수
  Future<void> launchMapAction(Map<String, dynamic> item) async {
    // 1. 로딩 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 15),
            Text("위치 정보를 확인 중입니다...",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    decoration: TextDecoration.none)),
          ],
        ),
      ),
    );

    void closeLoading() {
      if (context.mounted && Navigator.canPop(context)) Navigator.pop(context);
    }

    final selectedProvider = await loadSelectedProvider();
    final isTransport = storageKey == 'images_transport';
    final isCurrentToDestination = storageKey == 'images_hospital';
    final isRouteMode = isTransport || isCurrentToDestination;

    try {
      String sName = (item['sName'] ?? '').trim();
      String dName = (item['dName'] ?? '').trim();
      String location = (item['location'] ?? '').trim();

      double? sLat, sLng, dLat, dLng;

      if (isRouteMode) {
        // 카카오 현재 위치 길찾기는 출발 좌표를 직접 전달해야 합니다.
        if (isCurrentToDestination && selectedProvider == TYPE_KAKAO) {
          final position = await getCurrentPosition();
          sLat = position?.latitude;
          sLng = position?.longitude;
          if (position != null) sName = '현재 위치';
        }

        // 출발지 이름(sName)이 있으면 좌표 변환 시도
        if (sName.isNotEmpty) {
          try {
            List<Location> sLocs = await locationFromAddress(sName);
            if (sLocs.isNotEmpty) {
              sLat = sLocs.first.latitude;
              sLng = sLocs.first.longitude;
            }
          } catch (e) {/*무시*/}
        }
        // 도착지 이름(dName)이 있으면 좌표 변환 시도
        if (dName.isNotEmpty) {
          try {
            List<Location> dLocs = await locationFromAddress(dName);
            if (dLocs.isNotEmpty) {
              dLat = dLocs.first.latitude;
              dLng = dLocs.first.longitude;
            }
          } catch (e) {/*무시*/}
        }
      } else {
        if (location.isNotEmpty) {
          try {
            List<Location> locs = await locationFromAddress(location);
            if (locs.isNotEmpty) {
              dLat = locs.first.latitude;
              dLng = locs.first.longitude;
            }
          } catch (e) {/*무시*/}
        }
      }

      closeLoading(); // 로딩 종료

      final resolvedProvider = resolveProviderForAction(
        selectedProvider,
        storageKey,
        hasStartCoordinates: sLat != null && sLng != null,
        hasDestinationCoordinates: dLat != null && dLng != null,
      );

      if (resolvedProvider != selectedProvider) {
        if (selectedProvider == TYPE_TMAP && isTransport) {
          _showMessage('티맵은 버스·전철 출발지 연동이 되지 않아 인터넷 대중교통 길찾기로 연결합니다.');
        } else if (selectedProvider == TYPE_KAKAO &&
            isCurrentToDestination &&
            (sLat == null || sLng == null)) {
          _showMessage('현재 위치를 확인할 수 없어 인터넷 대중교통 길찾기로 연결합니다.');
        } else {
          _showMessage('주소 좌표를 확인할 수 없어 인터넷 지도에서 길찾기를 엽니다.');
        }
      }

      Uri? url = generateUrl(resolvedProvider, isRouteMode, sName, sLat, sLng,
          dName, dLat, dLng, location);
      var launched = false;
      if (url != null) {
        if (resolvedProvider == TYPE_WEB || await canLaunchUrl(url)) {
          launched = await _launchUrlSafe(url);
        }
      }

      if (!launched && resolvedProvider != TYPE_WEB) {
        _showMessage(
            '${providerName(selectedProvider)} 앱을 열 수 없어 인터넷 지도로 연결합니다.');
        final webUrl = generateUrl(TYPE_WEB, isRouteMode, sName, sLat, sLng,
            dName, dLat, dLng, location);
        if (webUrl != null) await _launchUrlSafe(webUrl);
      }
    } catch (e) {
      closeLoading();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('주소를 찾을 수 없습니다.')));
      }
    }
  }
}

Future<void> showMapAppSettingsDialog(BuildContext context) async {
  final selectedProvider = await MapActionUtils.loadSelectedProvider();
  if (!context.mounted) return;

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => _MapAppSettingsDialog(
      initialSelectedProvider: selectedProvider,
    ),
  );

  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('지도 앱 설정을 저장했습니다.')),
    );
  }
}

class _MapAppSettingsDialog extends StatefulWidget {
  final String initialSelectedProvider;

  const _MapAppSettingsDialog({
    required this.initialSelectedProvider,
  });

  @override
  State<_MapAppSettingsDialog> createState() => _MapAppSettingsDialogState();
}

class _MapAppSettingsDialogState extends State<_MapAppSettingsDialog> {
  late String _selectedProvider;

  @override
  void initState() {
    super.initState();
    _selectedProvider = widget.initialSelectedProvider;
  }

  String _providerName(String type) {
    switch (type) {
      case MapActionUtils.TYPE_NAVER:
        return '네이버 지도';
      case MapActionUtils.TYPE_KAKAO:
        return '카카오맵';
      case MapActionUtils.TYPE_TMAP:
        return '티맵 (TMAP)';
      case MapActionUtils.TYPE_GOOGLE:
        return '구글 지도';
      case MapActionUtils.TYPE_WEB:
        return '인터넷 지도';
      default:
        return type;
    }
  }

  String _providerDescription(String type) {
    switch (type) {
      case MapActionUtils.TYPE_NAVER:
        return '길찾기 · 대중교통';
      case MapActionUtils.TYPE_KAKAO:
        return '길찾기 · 대중교통';
      case MapActionUtils.TYPE_TMAP:
        return '자동차 길안내 · 장소 검색\n대중교통은 인터넷 지도로 연결';
      case MapActionUtils.TYPE_GOOGLE:
        return '길찾기 · 대중교통';
      case MapActionUtils.TYPE_WEB:
        return '대중교통 · 장소 검색';
      default:
        return '길찾기 · 장소 검색';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dialogHeight = (MediaQuery.sizeOf(context).height * 0.76)
        .clamp(360.0, 620.0)
        .toDouble();
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      title: const Text('열 지도 선택'),
      content: SizedBox(
        width: double.maxFinite,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '길찾기 버튼을 누르면 선택한 지도 하나만 엽니다.',
              style: TextStyle(color: Colors.black54, height: 1.35),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.separated(
                itemCount: MapActionUtils.supportedProviders.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final provider = MapActionUtils.supportedProviders[index];
                  final isSelected = provider == _selectedProvider;
                  return Semantics(
                    selected: isSelected,
                    button: true,
                    child: Material(
                      color: isSelected
                          ? Colors.teal.withValues(alpha: 0.09)
                          : Colors.black.withValues(alpha: 0.025),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        key: ValueKey('map-provider-$provider'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: () =>
                            setState(() => _selectedProvider = provider),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        _providerName(provider),
                                        maxLines: 1,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Icon(
                                    isSelected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: isSelected
                                        ? Colors.teal
                                        : Colors.black54,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _providerDescription(provider),
                                style: TextStyle(
                                  height: 1.3,
                                  color: provider == MapActionUtils.TYPE_TMAP
                                      ? Colors.deepOrange.shade700
                                      : Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () async {
            await MapActionUtils.saveSelectedProvider(_selectedProvider);
            if (context.mounted) Navigator.pop(context, true);
          },
          style: FilledButton.styleFrom(backgroundColor: Colors.teal),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

// ----------------------------------------------------
// 상세 페이지 (DetailGalleryPage)
// ----------------------------------------------------

class DetailGalleryPage extends StatefulWidget {
  final String title;
  final String description;
  final String storageKey;
  final bool isAdminMode;

  const DetailGalleryPage({
    super.key,
    required this.title,
    required this.description,
    required this.storageKey,
    required this.isAdminMode,
  });

  @override
  State<DetailGalleryPage> createState() => _DetailGalleryPageState();
}

// DataManagementMixin, AdminDialogsMixin 사용
class _DetailGalleryPageState extends State<DetailGalleryPage>
    with DataManagementMixin, AdminDialogsMixin {
  // DataManagementMixin에서 필요한 추상 getter 구현
  @override
  String get storageKey => widget.storageKey;
  @override
  String get description => widget.description;

  // Mixin에서 필요한 상태 변수 정의
  @override
  List<String> _imagePaths = [];
  @override
  String _currentDescription = "";
  @override
  List<Map<String, dynamic>> _routes = [];
  @override
  bool _isLoading = true;

  late MapActionUtils _mapActionUtils;

  @override
  void initState() {
    super.initState();
    _currentDescription = widget.description;
    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mapActionUtils = MapActionUtils(context, widget.storageKey);
  }

  @override
  void didUpdateWidget(covariant DetailGalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageKey != widget.storageKey) {
      _mapActionUtils = MapActionUtils(context, widget.storageKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 3번 폴더: 현재위치에서 목적지 (구 병원)
    bool isCurrentToDest = widget.storageKey == 'images_hospital';
    bool isTransport = widget.storageKey == 'images_transport';
    bool isRouteMode = isTransport || isCurrentToDest;

    // 아이콘과 색상 설정
    IconData mapButtonIcon = isCurrentToDest
        ? Icons.navigation // 길찾기 아이콘
        : (isTransport ? Icons.directions_bus : Icons.map_outlined);

    Color mapButtonColor = isCurrentToDest
        ? Colors.green.shade700 // 초록색 (안전한 느낌)
        : (isTransport ? Colors.blue.shade700 : Colors.deepOrange); // 파란색, 주황색

    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              widget.title,
              maxLines: 1,
              style: const TextStyle(fontSize: 26),
            ),
          ),
        ),
        toolbarHeight: 70,
        actions: [
          if (widget.isAdminMode) ...[
            // 설명 수정 버튼
            IconButton(
                icon: const Icon(Icons.edit_note, size: 32, color: Colors.blue),
                onPressed: _editDescriptionDialog),
          ],
          const SizedBox(width: 10),
        ],
      ),
      floatingActionButton: widget.isAdminMode
          ? FloatingActionButton.extended(
              onPressed: _addImage,
              icon: const Icon(Icons.add_a_photo),
              label: const Text('사진 추가'),
              backgroundColor: Colors.teal)
          : null,
      body: CustomScrollView(
        slivers: [
          // 관리자 모드일 때: 길찾기에 사용할 지도 선택 UI 표시
          if (widget.isAdminMode)
            SliverToBoxAdapter(
              child: Container(
                width: double.infinity,
                color: Colors.blueGrey.shade50,
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final useStackedLayout = constraints.maxWidth < 380 ||
                        MediaQuery.textScalerOf(context).scale(1) > 1.3;
                    final heading = const Row(
                      children: [
                        Icon(Icons.tune, color: Colors.deepPurple),
                        SizedBox(width: 10),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '길찾기 지도 설정',
                              maxLines: 1,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                    final selectButton = ElevatedButton.icon(
                      onPressed: () => showMapAppSettingsDialog(context),
                      icon: const Icon(Icons.tune),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('지도 앱 선택', maxLines: 1),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.deepPurple,
                        elevation: 1,
                      ),
                    );

                    if (useStackedLayout) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          heading,
                          const SizedBox(height: 8),
                          selectButton,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: 12),
                        selectButton,
                      ],
                    );
                  },
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: Colors.teal.withValues(alpha: 0.1),
              child: Column(
                children: [
                  Text(_currentDescription,
                      style: const TextStyle(fontSize: 22, height: 1.5),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 15),
                  if (isRouteMode || widget.storageKey == 'images_map') ...[
                    const SizedBox(height: 20),
                    ..._routes.asMap().entries.map((entry) {
                      int idx = entry.key;
                      Map<String, dynamic> item = entry.value;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GestureDetector(
                          onLongPress: widget.isAdminMode
                              ? () => _addOrEditRouteDialog(index: idx)
                              : null,
                          child: Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () =>
                                      _mapActionUtils.launchMapAction(item),
                                  icon: Icon(mapButtonIcon, size: 28),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: mapButtonColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(15)),
                                  ),
                                  label: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(item['name'] ?? '지도 보기',
                                          style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold)),
                                      const SizedBox(height: 4),

                                      // 텍스트 표시 로직
                                      Builder(builder: (context) {
                                        // 1. 일반 장소 검색 모드
                                        if (!isRouteMode) {
                                          return Text(item['location'] ?? '',
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  color: Colors.white70),
                                              overflow: TextOverflow.ellipsis);
                                        }

                                        // 2. 현재위치에서 목적지 모드 (출발지 표시 고정)
                                        if (isCurrentToDest) {
                                          return Text(
                                              '현재 위치 → ${item['dName']}',
                                              style: const TextStyle(
                                                  fontSize: 14,
                                                  color: Colors.white70),
                                              overflow: TextOverflow.ellipsis);
                                        }

                                        // 3. 버스/전철 모드 (출발지 -> 목적지)
                                        String sName = item['sName'] ?? '';
                                        String dName = item['dName'] ?? '';
                                        String label = sName.isNotEmpty
                                            ? '$sName → $dName'
                                            : '출발지 미정 → $dName';

                                        return Text(label,
                                            style: const TextStyle(
                                                fontSize: 14,
                                                color: Colors.white70),
                                            overflow: TextOverflow.ellipsis);
                                      }),
                                    ],
                                  ),
                                ),
                              ),
                              if (widget.isAdminMode)
                                IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.red),
                                    onPressed: () => _deleteRoute(idx)),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                    if (widget.isAdminMode)
                      TextButton.icon(
                          onPressed: () => _addOrEditRouteDialog(),
                          icon: const Icon(Icons.add_circle),
                          label: const Text('새 항목 추가',
                              style: TextStyle(fontSize: 18))),
                  ],
                ],
              ),
            ),
          ),
          if (_isLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_imagePaths.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('사진이 없습니다.')),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                widget.isAdminMode ? 90 : 16,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return GestureDetector(
                      onLongPress:
                          widget.isAdminMode ? () => _deleteImage(index) : null,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 25),
                        child: Image.file(
                          File(_imagePaths[index]),
                          fit: BoxFit.cover,
                        ),
                      ),
                    );
                  },
                  childCount: _imagePaths.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
