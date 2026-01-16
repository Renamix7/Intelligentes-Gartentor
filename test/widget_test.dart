import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gartentor/main.dart'; // <- Adjust the import path to your project

void main() {
  Future<void> loginAs(
    WidgetTester tester, {
    required String user,
    required String pass,
  }) async {
    await tester.pumpWidget(const GateApp());

    // Login screen visible
    expect(find.text('Login'), findsOneWidget);

    // Fill in fields
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username (admin/user)'), user);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Passwort (admin/user)'), pass);

    // Log in
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    // async login (350 ms delay) + settle
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('Login als admin zeigt Dashboard mit Admin-Tab',
      (WidgetTester tester) async {
    await loginAs(tester, user: 'admin', pass: 'admin');

    // Dashboard visible
    expect(find.text(' Intelligentes Gartentor'), findsOneWidget);

    // Tabs available
    expect(find.text('Anfragen'), findsOneWidget);
    expect(find.text('Kennzeichen'), findsOneWidget);
    expect(find.text('Protokoll'), findsOneWidget);
    expect(find.text('Benutzer'), findsOneWidget); // admin only
  });

  testWidgets('Anfrage simulieren -> im Protokoll als "opened"/"denied" sichtbar',
      (WidgetTester tester) async {
    await loginAs(tester, user: 'admin', pass: 'admin');

    // Simulate an access request (FAB)
    final fab = find.byType(FloatingActionButton);
    expect(fab, findsOneWidget);
    await tester.tap(fab);
    await tester.pump(); // SnackBar animates
    // SnackBar text appears
    expect(find.textContaining('Zutrittsanfrage:'), findsOneWidget);

    // The requests list should now contain an entry
    expect(find.textContaining('Kennzeichen:'), findsWidgets);

    // Request "Open"
    await tester.tap(find.widgetWithText(ElevatedButton, 'Öffnen').first);
    await tester.pumpAndSettle();

    // Switch to "Protokoll" tab
    await tester.tap(find.text('Protokoll'));
    await tester.pumpAndSettle();

    // Log entry contains "opened"
    expect(find.textContaining('opened —'), findsOneWidget);
  });

  testWidgets('Kennzeichen hinzufügen (permanent) erscheint in der Liste',
      (WidgetTester tester) async {
    await loginAs(tester, user: 'admin', pass: 'admin');

    // Switch to "Kennzeichen" tab
    await tester.tap(find.text('Kennzeichen'));
    await tester.pumpAndSettle();

    // Enter license plate
    const newPlate = 'T-TEST1';
    await tester.enterText(
      find.widgetWithText(TextField, 'Kennzeichen'),
      newPlate,
    );

    // Add
    await tester.tap(find.widgetWithText(FilledButton, 'Hinzufügen'));
    await tester.pumpAndSettle();

    // Present in the list
    expect(find.text(newPlate), findsWidgets);
    expect(find.text('Dauerhaft'), findsWidgets);
  });

  testWidgets('Logout bringt zurück zum Login', (WidgetTester tester) async {
    await loginAs(tester, user: 'admin', pass: 'admin');

    // Logout icon in AppBar
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(find.text('Login'), findsOneWidget);
  });
}
