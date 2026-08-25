import 'package:flutter_test/flutter_test.dart';
import 'package:grandparents_map/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapActionUtils single map selection', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults invalid selections to Naver', () {
      expect(
        MapActionUtils.normalizeSelectedProvider('unknown'),
        MapActionUtils.TYPE_NAVER,
      );
    });

    test('saves and loads one selected provider', () async {
      await MapActionUtils.saveSelectedProvider(MapActionUtils.TYPE_KAKAO);

      expect(
        await MapActionUtils.loadSelectedProvider(),
        MapActionUtils.TYPE_KAKAO,
      );
    });

    test('migrates the first enabled provider from the old settings', () async {
      SharedPreferences.setMockInitialValues({
        'map_priority': ['google', 'naver', 'kakao', 'tmap', 'web'],
        'map_enabled': ['naver', 'web'],
      });

      expect(
        await MapActionUtils.loadSelectedProvider(),
        MapActionUtils.TYPE_NAVER,
      );
    });

    test('uses web transit instead of losing a TMAP transport origin', () {
      expect(
        MapActionUtils.resolveProviderForAction(
          MapActionUtils.TYPE_TMAP,
          'images_transport',
          hasStartCoordinates: true,
          hasDestinationCoordinates: true,
        ),
        MapActionUtils.TYPE_WEB,
      );
    });

    test('uses web if Kakao current position is unavailable', () {
      expect(
        MapActionUtils.resolveProviderForAction(
          MapActionUtils.TYPE_KAKAO,
          'images_hospital',
          hasStartCoordinates: false,
          hasDestinationCoordinates: true,
        ),
        MapActionUtils.TYPE_WEB,
      );
    });
  });

  group('MapActionUtils route links', () {
    test('passes an explicit origin and destination to Naver transit', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_NAVER,
        true,
        '서울역',
        37.5547,
        126.9706,
        '서울시청',
        37.5663,
        126.9779,
        null,
      );

      expect(uri?.scheme, 'nmap');
      expect(uri?.host, 'route');
      expect(uri?.path, '/public');
      expect(uri?.queryParameters['slat'], '37.5547');
      expect(uri?.queryParameters['slng'], '126.9706');
      expect(uri?.queryParameters['dlat'], '37.5663');
      expect(uri?.queryParameters['dlng'], '126.9779');
      expect(uri?.queryParameters['sname'], '서울역');
      expect(uri?.queryParameters['dname'], '서울시청');
      expect(uri?.queryParameters['appname'], androidApplicationId);
    });

    test('lets Naver use device location when current origin is omitted', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_NAVER,
        true,
        '',
        null,
        null,
        '서울시청',
        37.5663,
        126.9779,
        null,
      );

      expect(uri?.queryParameters, isNot(contains('slat')));
      expect(uri?.queryParameters['dlat'], '37.5663');
      expect(uri?.queryParameters['dlng'], '126.9779');
    });

    test('passes current coordinates and destination to Kakao transit', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_KAKAO,
        true,
        '현재 위치',
        37.5547,
        126.9706,
        '서울시청',
        37.5663,
        126.9779,
        null,
      );

      expect(uri?.scheme, 'kakaomap');
      expect(uri?.host, 'route');
      expect(uri?.queryParameters['by'], 'publictransit');
      expect(uri?.queryParameters['sp'], '37.5547,126.9706');
      expect(uri?.queryParameters['ep'], '37.5663,126.9779');
    });

    test('passes an explicit origin and destination to Google transit', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_GOOGLE,
        true,
        '서울역',
        37.5547,
        126.9706,
        '서울시청',
        37.5663,
        126.9779,
        null,
      );

      expect(uri?.scheme, 'https');
      expect(uri?.host, 'www.google.com');
      expect(uri?.queryParameters['api'], '1');
      expect(uri?.queryParameters['travelmode'], 'transit');
      expect(uri?.queryParameters['origin'], '37.5547,126.9706');
      expect(uri?.queryParameters['destination'], '37.5663,126.9779');
    });

    test('lets Google use device location when current origin is omitted', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_GOOGLE,
        true,
        '',
        null,
        null,
        '서울시청',
        37.5663,
        126.9779,
        null,
      );

      expect(uri?.queryParameters, isNot(contains('origin')));
      expect(uri?.queryParameters['destination'], '37.5663,126.9779');
      expect(uri?.queryParameters['travelmode'], 'transit');
    });

    test('passes a destination to TMAP car navigation', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_TMAP,
        true,
        '',
        null,
        null,
        '서울시청',
        37.5663,
        126.9779,
        null,
      );

      expect(uri?.scheme, 'tmap');
      expect(uri?.host, 'route');
      expect(uri?.queryParameters['goalname'], '서울시청');
      expect(uri?.queryParameters['goalx'], '126.9779');
      expect(uri?.queryParameters['goaly'], '37.5663');
    });

    test('keeps address text in the browser transit fallback', () {
      final uri = MapActionUtils.generateUrl(
        MapActionUtils.TYPE_WEB,
        true,
        '서울역',
        null,
        null,
        '서울시청',
        null,
        null,
        null,
      );

      expect(uri?.queryParameters['origin'], '서울역');
      expect(uri?.queryParameters['destination'], '서울시청');
      expect(uri?.queryParameters['travelmode'], 'transit');
    });
  });

  group('MapActionUtils place search links', () {
    for (final provider in MapActionUtils.supportedProviders) {
      test('creates a place search link for $provider', () {
        final uri = MapActionUtils.generateUrl(
          provider,
          false,
          null,
          null,
          null,
          null,
          null,
          null,
          '서울시청',
        );

        expect(uri, isNotNull);
        expect(uri.toString(), contains(Uri.encodeComponent('서울시청')));
      });
    }
  });

  group('SafetyUtils', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saves and loads the home address', () async {
      await SafetyUtils.saveSettings(
        homeAddress: ' 서울시 중구 세종대로 110 ',
      );

      final settings = await SafetyUtils.loadSettings();
      expect(settings.homeAddress, '서울시 중구 세종대로 110');
    });

    test('builds a Korean reverse address request', () {
      final uri = SafetyUtils.buildReverseGeocodingUri(37.5663, 126.9779);

      expect(uri.scheme, 'https');
      expect(uri.host, 'nominatim.openstreetmap.org');
      expect(uri.path, '/reverse');
      expect(uri.queryParameters['format'], 'jsonv2');
      expect(uri.queryParameters['accept-language'], 'ko');
      expect(uri.queryParameters['addressdetails'], '1');
    });

    test('turns reverse geocoding data into a readable Korean address', () {
      final address = SafetyUtils.addressFromNominatimData({
        'display_name': '110, 세종대로, 중구, 서울특별시, 대한민국',
        'address': {
          'state': '서울특별시',
          'city': '서울특별시',
          'borough': '중구',
          'road': '세종대로',
          'house_number': '110',
          'country': '대한민국',
        },
      });

      expect(address, '서울특별시 중구 세종대로 110');
      expect(address, isNot(contains('위도')));
      expect(address, isNot(contains('경도')));
    });
  });
}
