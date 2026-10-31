import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// ---------- Language strings (English + Hindi) ----------
const Map<String, Map<String, String>> L = {
  'en': {
    'title': 'Smart Expiry Reminder', 'add': 'Add item', 'name': 'Name',
    'category': 'Category', 'owner': 'Whose item (optional)',
    'expiry': 'Expiry date (DD/MM/YYYY)', 'opened': 'Opened on (optional)',
    'after': 'Good after opening (months)', 'save': 'Save',
    'settings': 'Settings', 'language': 'Language', 'first': 'Use this first',
    'alert': 'Expired or expiring within 7 days', 'all': 'All',
    'medicine': 'Medicine', 'fridge': 'Fridge', 'grocery': 'Grocery',
    'household': 'Household', 'invalid': 'Name and a valid expiry date are required',
    'empty': 'No items yet. Tap + to add one.', 'notif': 'Expiry alert',
    'used': 'Used', 'delete': 'Delete',
  },
  'hi': {
    'title': 'स्मार्ट एक्सपायरी रिमाइंडर', 'add': 'आइटम जोड़ें', 'name': 'नाम',
    'category': 'श्रेणी', 'owner': 'किसका है (वैकल्पिक)',
    'expiry': 'एक्सपायरी तारीख (DD/MM/YYYY)', 'opened': 'खोलने की तारीख (वैकल्पिक)',
    'after': 'खोलने के बाद कितने महीने चलता है', 'save': 'सेव करें',
    'settings': 'सेटिंग्स', 'language': 'भाषा', 'first': 'इसे सबसे पहले इस्तेमाल करें',
    'alert': 'एक्सपायर हो चुके या 7 दिन में होने वाले', 'all': 'सब',
    'medicine': 'दवाई', 'fridge': 'फ्रिज', 'grocery': 'किराना',
    'household': 'घर का सामान', 'invalid': 'नाम और सही एक्सपायरी तारीख ज़रूरी है',
    'empty': 'अभी कोई आइटम नहीं। जोड़ने के लिए + दबाएँ।', 'notif': 'एक्सपायरी अलर्ट',
    'used': 'इस्तेमाल हो गया', 'delete': 'हटाएँ',
  },
};
const cats = ['medicine', 'fridge', 'grocery', 'household'];
const icons = {'medicine': '💊', 'fridge': '🧊', 'grocery': '🛒', 'household': '🧴'};

String daysText(int n, String lang) {
  final hi = lang == 'hi';
  if (n < 0) return hi ? '${-n} दिन पहले एक्सपायर' : 'Expired ${-n} days ago';
  if (n == 0) return hi ? 'आज एक्सपायर' : 'Expires today';
  if (n == 1) return hi ? 'कल एक्सपायर' : 'Expires tomorrow';
  return hi ? '$n दिन बाकी' : '$n days left';
}

Color tone(int n) => n < 0 ? Colors.red : (n <= 30 ? Colors.orange : Colors.green);
String two(int n) => n.toString().padLeft(2, '0');
String fmt(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';

// ---------- Model ----------
class Item {
  final int id; // also used for notification ids
  final String name, cat, owner;
  final DateTime exp;
  final DateTime? opened;
  final int? after;
  Item(this.id, this.name, this.cat, this.owner, this.exp, this.opened, this.after);

  DateTime get effective {
    var e = exp;
    if (opened != null && after != null) {
      final o = DateTime(opened!.year, opened!.month + after!, opened!.day);
      if (o.isBefore(e)) e = o;
    }
    return e;
  }

  int get daysLeft {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    return (effective.difference(today).inHours / 24).round();
  }

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'cat': cat, 'owner': owner,
        'exp': exp.toIso8601String(), 'opened': opened?.toIso8601String(), 'after': after,
      };
  factory Item.fromJson(Map<String, dynamic> j) => Item(
        j['id'], j['name'], j['cat'], j['owner'] ?? '', DateTime.parse(j['exp']),
        j['opened'] == null ? null : DateTime.parse(j['opened']), j['after']);
}

// ---------- Date input helpers ----------
class DateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue o, TextEditingValue n) {
    var v = n.text.replaceAll(RegExp(r'\D'), '');
    if (v.length > 8) v = v.substring(0, 8);
    var out = v;
    if (v.length > 4) {
      out = '${v.substring(0, 2)}/${v.substring(2, 4)}/${v.substring(4)}';
    } else if (v.length > 2) {
      out = '${v.substring(0, 2)}/${v.substring(2)}';
    }
    return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: out.length));
  }
}

DateTime? parseDate(String s) {
  final m = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(s.trim());
  if (m == null) return null;
  final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
  final dt = DateTime(y, mo, d);
  return (dt.year == y && dt.month == mo && dt.day == d) ? dt : null;
}

// ---------- Notifications (work even when the app is closed) ----------
final plugin = FlutterLocalNotificationsPlugin();
const _details = NotificationDetails(
  android: AndroidNotificationDetails('expiry', 'Expiry alerts',
      importance: Importance.high, priority: Priority.high),
  iOS: DarwinNotificationDetails(),
);

Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()));
  await plugin.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  ));
  // Asks the user for permission (Android 13+ and iOS)
  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  await plugin
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
}

// Reminders at 9:00 AM: 7 days before, 1 day before, and on the expiry day
Future<void> scheduleFor(Item i, String lang) async {
  const offsets = [7, 1, 0];
  for (var k = 0; k < offsets.length; k++) {
    final d = offsets[k];
    final e = i.effective;
    final when = DateTime(e.year, e.month, e.day - d, 9);
    if (when.isBefore(DateTime.now())) continue;
    await plugin.zonedSchedule(
      i.id * 10 + k,
      '⚠️ ${L[lang]!['notif']}',
      '${icons[i.cat]} ${i.name}: ${daysText(d, lang)}',
      tz.TZDateTime.from(when, tz.local),
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}

Future<void> cancelFor(Item i) async {
  for (var k = 0; k < 3; k++) {
    await plugin.cancel(i.id * 10 + k);
  }
}

// ---------- App ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1F7A5A), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF1F7A5A), brightness: Brightness.dark, useMaterial3: true),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Item> items = [];
  String lang = 'hi', filter = 'all';
  SharedPreferences? prefs;
  String t(String k) => L[lang]![k]!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    prefs = await SharedPreferences.getInstance();
    lang = prefs!.getString('lang') ?? 'hi';
    items = (prefs!.getStringList('items') ?? [])
        .map((s) => Item.fromJson(jsonDecode(s)))
        .toList();
    setState(() {});
  }

  Future<void> _save() =>
      prefs!.setStringList('items', items.map((i) => jsonEncode(i.toJson())).toList());

  Future<void> _add() async {
    final item = await Navigator.push<Item>(
        context, MaterialPageRoute(builder: (_) => AddPage(lang: lang)));
    if (item == null) return;
    items.add(item);
    await _save();
    await scheduleFor(item, lang);
    setState(() {});
  }

  Future<void> _remove(Item i) async {
    items.remove(i);
    await _save();
    await cancelFor(i);
    setState(() {});
  }

  Future<void> _setLang(String l) async {
    lang = l;
    await prefs!.setString('lang', l);
    for (final i in items) {
      await cancelFor(i);
      await scheduleFor(i, l);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]..sort((a, b) => a.effective.compareTo(b.effective));
    final shown = sorted.where((i) => filter == 'all' || i.cat == filter).toList();
    final urgent = sorted.where((i) => i.daysLeft <= 7).toList();
    return Scaffold(
      appBar: AppBar(title: Text('⏳ ${t('title')}'), actions: [
        IconButton(
          icon: const Icon(Icons.settings),
          tooltip: t('settings'),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => SettingsPage(lang: lang, onLang: _setLang))),
        ),
      ]),
      floatingActionButton:
          FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: Text(t('add'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (urgent.isNotEmpty)
          Card(
            color: urgent.any((i) => i.daysLeft < 0) ? Colors.red.withOpacity(.15) : Colors.orange.withOpacity(.15),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('⚠️ ${urgent.length} · ${t('alert')}', style: const TextStyle(fontWeight: FontWeight.bold)),
                for (final i in urgent.take(5)) Text('${icons[i.cat]} ${i.name}: ${daysText(i.daysLeft, lang)}'),
              ]),
            ),
          ),
        if (sorted.isNotEmpty)
          Card(
            child: ListTile(
              title: Text(t('first'), style: const TextStyle(fontSize: 12)),
              subtitle: Text('${icons[sorted.first.cat]} ${sorted.first.name}\n${daysText(sorted.first.daysLeft, lang)} · ${fmt(sorted.first.effective)}',
                  style: const TextStyle(fontSize: 16)),
              isThreeLine: true,
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final c in ['all', ...cats])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(t(c)), selected: filter == c, onSelected: (_) => setState(() => filter = c)),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(t('empty')))),
        for (final i in shown)
          Card(
            child: ListTile(
              leading: Text(icons[i.cat]!, style: const TextStyle(fontSize: 28)),
              title: Text(i.name),
              subtitle: Text('${fmt(i.effective)}${i.owner.isEmpty ? '' : ' · ${i.owner}'}\n${daysText(i.daysLeft, lang)}',
                  style: TextStyle(color: tone(i.daysLeft))),
              isThreeLine: true,
              trailing: IconButton(icon: const Icon(Icons.check_circle_outline), tooltip: t('used'), onPressed: () => _remove(i)),
              onLongPress: () => _remove(i),
            ),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }
}

class AddPage extends StatefulWidget {
  final String lang;
  const AddPage({super.key, required this.lang});
  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  final name = TextEditingController(), owner = TextEditingController(),
      exp = TextEditingController(), opened = TextEditingController(), after = TextEditingController();
  String cat = 'medicine';
  String t(String k) => L[widget.lang]![k]!;

  void _submit() {
    final e = parseDate(exp.text);
    if (name.text.trim().isEmpty || e == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('invalid'))));
      return;
    }
    Navigator.pop(
        context,
        Item(DateTime.now().millisecondsSinceEpoch % 200000000, name.text.trim(), cat, owner.text.trim(), e,
            parseDate(opened.text), int.tryParse(after.text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('add'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // autofocus opens the keyboard automatically
        TextField(controller: name, autofocus: true, textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: t('name'))),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: cat,
          decoration: InputDecoration(labelText: t('category')),
          items: [for (final c in cats) DropdownMenuItem(value: c, child: Text('${icons[c]} ${t(c)}'))],
          onChanged: (v) => setState(() => cat = v!),
        ),
        const SizedBox(height: 12),
        TextField(controller: exp, keyboardType: TextInputType.number, inputFormatters: [DateFormatter()], textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: t('expiry'), hintText: 'DD/MM/YYYY')),
        const SizedBox(height: 12),
        TextField(controller: opened, keyboardType: TextInputType.number, inputFormatters: [DateFormatter()], textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: t('opened'), hintText: 'DD/MM/YYYY')),
        const SizedBox(height: 12),
        TextField(controller: after, keyboardType: TextInputType.number, textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: t('after'))),
        const SizedBox(height: 12),
        TextField(controller: owner, textInputAction: TextInputAction.done, decoration: InputDecoration(labelText: t('owner'))),
        const SizedBox(height: 20),
        FilledButton(onPressed: _submit, child: Text(t('save'))),
      ]),
    );
  }
}

class SettingsPage extends StatelessWidget {
  final String lang;
  final Future<void> Function(String) onLang;
  const SettingsPage({super.key, required this.lang, required this.onLang});
  @override
  Widget build(BuildContext context) {
    final t = L[lang]!;
    return Scaffold(
      appBar: AppBar(title: Text(t['settings']!)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t['language']!),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'en', label: Text('English')),
              ButtonSegment(value: 'hi', label: Text('हिन्दी')),
            ],
            selected: {lang},
            onSelectionChanged: (s) async {
              await onLang(s.first);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ]),
      ),
    );
  }
}
