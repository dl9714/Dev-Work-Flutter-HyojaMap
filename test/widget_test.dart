// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grandparents_map/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Build our app and trigger a frame.
    await tester.pumpWidget(const GrandparentsMapApp());

    // Verify that the title exists.
    expect(find.text(appTitle), findsOneWidget);
    expect(find.text(appVersion), findsOneWidget);
    expect(
      find.byKey(const ValueKey('current-location-appbar-button')),
      findsOneWidget,
    );
    expect(find.text('집 주변 지도'), findsOneWidget);
    expect(find.text('버스 및 전철 가는 길'), findsOneWidget);
    expect(find.text('현재위치에서 목적지 가는 길'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('현재위치에서 목적지 가는 길')).dy,
      lessThan(tester.getTopLeft(find.text('집 주변 지도')).dy),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('folder-card-현재위치에서 목적지 가는 길')))
          .height,
      lessThan(230),
    );
  });

  testWidgets('Admin can select exactly one map without overflow',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const GrandparentsMapApp());
    await tester.tap(find.byTooltip('관리자 모드 켜기'));
    await tester.pumpAndSettle();
    expect(find.text('자녀가 변경해 주세요'), findsOneWidget);
    expect(
      find.text('휴대폰을 누르다가 사진이나 길찾기 정보가 실수로 바뀌거나 삭제되는 것을 막기 위한 보호 기능입니다.'),
      findsOneWidget,
    );
    expect(find.text('관리자 비밀번호: 0000 (항상 동일)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '0000');
    await tester.tap(find.widgetWithText(ElevatedButton, '확인'));
    await tester.pumpAndSettle();

    expect(find.text('관리자 모드'), findsOneWidget);
    expect(find.text('집 주소'), findsOneWidget);
    expect(find.text('지도 설정'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('집 주소'));
    await tester.pumpAndSettle();
    expect(find.text('집 주소 설정'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('home-address-field')),
      '서울시 중구 세종대로 110',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    final safetySettings = await SafetyUtils.loadSettings();
    expect(safetySettings.homeAddress, '서울시 중구 세종대로 110');

    await tester.tap(find.text('지도 설정'));
    await tester.pumpAndSettle();

    expect(find.text('열 지도 선택'), findsOneWidget);
    expect(find.text('길찾기 버튼을 누르면 선택한 지도 하나만 엽니다.'), findsOneWidget);
    expect(find.text('네이버 지도'), findsOneWidget);
    expect(find.text('카카오맵'), findsOneWidget);
    expect(find.text('티맵 (TMAP)'), findsOneWidget);
    expect(find.text('구글 지도'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('map-provider-kakao')));
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    expect(
      await MapActionUtils.loadSelectedProvider(),
      MapActionUtils.TYPE_KAKAO,
    );

    await tester.tap(find.text('지도 설정'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('map-provider-kakao')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Large phone text mode has no overflow',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(300, 650);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const GrandparentsMapApp());
    expect(
      find.byKey(const ValueKey('current-location-appbar-button')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('folder-card-집 주변 지도')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const ValueKey('folder-card-집 주변 지도')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 2000),
      1000,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('관리자 모드 켜기'));
    await tester.pumpAndSettle();
    expect(find.text('자녀가 변경해 주세요'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), '0000');
    await tester.tap(find.widgetWithText(ElevatedButton, '확인'));
    await tester.pumpAndSettle();
    expect(find.text('관리자 모드'), findsOneWidget);
    expect(find.text('집 주소'), findsOneWidget);
    expect(find.text('지도 설정'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('지도 설정'));
    await tester.pumpAndSettle();
    expect(find.text('열 지도 선택'), findsOneWidget);
    expect(find.text('네이버 지도'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('map-provider-web')),
      220,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('인터넷 지도'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Large text detail title and admin controls stay readable',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(300, 650);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      const MaterialApp(
        home: DetailGalleryPage(
          storageKey: 'images_hospital',
          title: '현재위치에서 목적지 가는 길',
          description: '지금 계신 곳에서 목적지까지 가는 방법입니다.',
          isAdminMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('현재위치에서 목적지 가는 길'), findsOneWidget);
    expect(find.text('길찾기 지도 설정'), findsOneWidget);
    expect(find.text('지도 앱 선택'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Current location map shows a map and location marker',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CurrentLocationMap(
            latitude: 37.5663,
            longitude: 126.9779,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('current-location-map')),
      findsOneWidget,
    );
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(MarkerLayer), findsOneWidget);
    expect(find.byType(RichAttributionWidget), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
