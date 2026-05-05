// ============================================================================
//  VibeStory — main.dart  v3.0
//  Changes: Dev Mode, Theme (system/light/dark), Audio fix (WAV),
//           Refresh buttons, Settings screen, YOLO bbox saving, cleanup
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ── Server URL — dynamic, can be overridden by ngrok URL ─────────────────────
// LAN:  'http://192.168.X.X:8000'   (find IP with `ipconfig` or `ip a`)
// USB:  'http://localhost:8000'      (after `adb reverse tcp:8000 tcp:8000`)
const String kDefaultBaseUrl = 'http://192.168.31.201:8000';

/// Holds the active server URL. Can be overridden at runtime with a ngrok URL.
/// Use [ServerConfig.baseUrl] everywhere instead of kBaseUrl directly.
class ServerConfig {
  static String _url = kDefaultBaseUrl;

  static String get baseUrl => _url;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('custom_server_url');
    if (saved != null && saved.isNotEmpty) _url = saved;
  }

  static Future<void> setUrl(String url) async {
    // Normalise — strip trailing slash
    final clean = url.trim().replaceAll(RegExp(r'/$'), '');
    _url = clean.isEmpty ? kDefaultBaseUrl : clean;
    final p = await SharedPreferences.getInstance();
    if (clean.isEmpty) {
      await p.remove('custom_server_url');
    } else {
      await p.setString('custom_server_url', _url);
    }
  }

  static Future<void> clear() async {
    _url = kDefaultBaseUrl;
    final p = await SharedPreferences.getInstance();
    await p.remove('custom_server_url');
  }

  static bool get isCustom => _url != kDefaultBaseUrl;
}

// ── Palette ───────────────────────────────────────────────────────────────────
const Color kPrimary  = Color(0xFFFF6B6B);
const Color kSecondary= Color(0xFFFFE66D);
const Color kAccent   = Color(0xFF4ECDC4);
const Color kPurple   = Color(0xFFA78BFA);
const Color kGreen    = Color(0xFF6BCB77);
const Color kBgLight  = Color(0xFFFFF9F0);
const Color kCardLight= Color(0xFFFFFFFF);
const Color kTextLight= Color(0xFF3D2C2C);
const Color kSubLight = Color(0xFF7B6060);
const Color kBgDark   = Color(0xFF1A1A2E);
const Color kCardDark = Color(0xFF16213E);
const Color kTextDark = Color(0xFFE0E0E0);
const Color kSubDark  = Color(0xFFAAAAAA);

// ── App-wide state (simple singleton) ────────────────────────────────────────
class AppState extends ChangeNotifier {
  static final AppState _i = AppState._();
  factory AppState() => _i;
  AppState._();

  ThemeMode _themeMode = ThemeMode.system;
  bool _devMode = false;

  ThemeMode get themeMode => _themeMode;
  bool get devMode => _devMode;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString('theme_mode') ?? 'system';
    _themeMode = t == 'light' ? ThemeMode.light
               : t == 'dark'  ? ThemeMode.dark
               : ThemeMode.system;
    _devMode = p.getBool('dev_mode') ?? false;
    await ServerConfig.load();
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode m) async {
    _themeMode = m;
    final p = await SharedPreferences.getInstance();
    await p.setString('theme_mode',
        m == ThemeMode.light ? 'light'
      : m == ThemeMode.dark  ? 'dark'
      : 'system');
    notifyListeners();
  }

  Future<void> setDevMode(bool v) async {
    _devMode = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('dev_mode', v);
    notifyListeners();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState().load();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));
  runApp(const VibeStoryApp());
}

class VibeStoryApp extends StatefulWidget {
  const VibeStoryApp({super.key});
  @override
  State<VibeStoryApp> createState() => _VibeStoryAppState();
}

class _VibeStoryAppState extends State<VibeStoryApp> {
  @override
  void initState() {
    super.initState();
    AppState().addListener(_rebuild);
  }
  void _rebuild() => setState(() {});
  @override
  void dispose() { AppState().removeListener(_rebuild); super.dispose(); }

  ThemeData _buildTheme(Brightness b) {
    final isDark = b == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: kPrimary, brightness: b),
      scaffoldBackgroundColor: isDark ? kBgDark : kBgLight,
      textTheme: GoogleFonts.nunitoTextTheme(
          isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme),
      cardColor: isDark ? kCardDark : kCardLight,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: kPrimary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VibeStory',
        debugShowCheckedModeBanner: false,
        themeMode: AppState().themeMode,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: const SplashScreen(),
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  THEME HELPERS
// ════════════════════════════════════════════════════════════════════════════
Color kBg(BuildContext ctx)     => Theme.of(ctx).scaffoldBackgroundColor;
Color kCard(BuildContext ctx)   => Theme.of(ctx).cardColor;
Color kText(BuildContext ctx)   => Theme.of(ctx).brightness == Brightness.dark
    ? kTextDark : kTextLight;
Color kSub(BuildContext ctx)    => Theme.of(ctx).brightness == Brightness.dark
    ? kSubDark  : kSubLight;

// ════════════════════════════════════════════════════════════════════════════
//  API SERVICE
// ════════════════════════════════════════════════════════════════════════════
class Api {
  static String? _token;

  static Future<void> loadToken() async {
    final p = await SharedPreferences.getInstance();
    _token = p.getString('token');
  }

  static Future<void> saveToken(String t) async {
    _token = t;
    final p = await SharedPreferences.getInstance();
    await p.setString('token', t);
  }

  static Future<void> clearToken() async {
    _token = null;
    final p = await SharedPreferences.getInstance();
    await p.remove('token');
    await p.remove('user_name');
  }

  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'ngrok-skip-browser-warning': 'true',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  static Future<Map<String, dynamic>> post(String path, Map body) async {
    final url = '${ServerConfig.baseUrl}$path';
    print('>>> POST $url');          // ← add
    print('>>> HEADERS: $_headers'); // ← add
    final r = await http.post(Uri.parse(url),
        headers: _headers, body: jsonEncode(body));
    print('>>> STATUS: ${r.statusCode}');  // ← add
    print('>>> BODY: ${r.body}');          // ← add
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode >= 400) throw data['detail'] ?? 'Error';
    return data;
  }

  static Future<Map<String, dynamic>> get(String path) async {
    final r = await http.get(Uri.parse('${ServerConfig.baseUrl}$path'), headers: _headers);
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode >= 400) throw data['detail'] ?? 'Error';
    return data;
  }

  static Future<Map<String, dynamic>> uploadAudio(
      String path, String filePath) async {
    final req = http.MultipartRequest('POST', Uri.parse('${ServerConfig.baseUrl}$path'));
    req.headers['Authorization'] = 'Bearer $_token';
    req.headers['ngrok-skip-browser-warning'] = 'true';
    req.files.add(await http.MultipartFile.fromPath('audio', filePath));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> uploadImageBytes(
      String path, Uint8List bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('${ServerConfig.baseUrl}$path'));
    req.headers['Authorization'] = 'Bearer $_token';
    req.headers['ngrok-skip-browser-warning'] = 'true';
    req.files.add(http.MultipartFile.fromBytes('image', bytes,
        filename: filename, contentType: MediaType('image', 'jpeg')));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    return jsonDecode(body) as Map<String, dynamic>;
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  DOODLE WIDGETS
// ════════════════════════════════════════════════════════════════════════════
class DoodleCard extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsets? padding;
  const DoodleCard({super.key, required this.child, this.color, this.padding});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color ?? kCard(context),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20), topRight: Radius.circular(24),
            bottomLeft: Radius.circular(26), bottomRight: Radius.circular(18),
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.07),
                blurRadius: 12, offset: const Offset(3, 5)),
          ],
        ),
        child: child,
      );
}

class DoodleButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final IconData? icon;
  final bool wide;
  const DoodleButton({super.key, required this.label, this.onTap,
      this.color = kPrimary, this.icon, this.wide = false});
  @override
  State<DoodleButton> createState() => _DoodleButtonState();
}

class _DoodleButtonState extends State<DoodleButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: 80.ms)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _ctrl.reverse();
        });
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onTap == null ? null : () {
          _ctrl.forward(); widget.onTap!();
        },
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, child) =>
              Transform.scale(scale: 1 - _ctrl.value * 0.06, child: child),
          child: Container(
            width: widget.wide ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16), topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20), bottomRight: Radius.circular(14),
              ),
              boxShadow: [
                BoxShadow(color: widget.color.withOpacity(0.40),
                    blurRadius: 8, offset: const Offset(0, 4)),
              ],
            ),
            child: Row(
              mainAxisSize: widget.wide ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                ],
                Text(widget.label,
                    style: GoogleFonts.nunito(
                        color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
          ),
        ),
      );
}

extension _DurX on int {
  Duration get ms => Duration(milliseconds: this);
}

// ════════════════════════════════════════════════════════════════════════════
//  SPLASH SCREEN
// ════════════════════════════════════════════════════════════════════════════
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2)).then((_) async {
      await Api.loadToken();
      if (!mounted) return;
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) =>
              Api._token != null ? const MainNav() : const AuthScreen()));
    });
  }

  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kPrimary,
        body: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Transform.rotate(
                  angle: _ctrl.value * 0.15,
                  child: const Text('📖', style: TextStyle(fontSize: 80))),
            ),
            const SizedBox(height: 20),
            Text('VibeStory',
                style: GoogleFonts.pacifico(
                    fontSize: 42, color: Colors.white, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            Text('Your magical story world ✨',
                style: GoogleFonts.nunito(color: Colors.white70, fontSize: 16)),
          ]),
        ),
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  AUTH SCREEN
// ════════════════════════════════════════════════════════════════════════════
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  bool _isLogin = true, _loading = false;
  String? _error;
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  late final AnimationController _bgCtrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat(reverse: true);

  // ── Hidden ngrok URL feature ──────────────────────────────────────────────
  int  _logoTapCount   = 0;
  bool _showNgrokPanel = false;
  final _ngrokCtrl     = TextEditingController();
  bool _ngrokTesting   = false;
  String? _ngrokStatus;

  @override
  void initState() {
    super.initState();
    _ngrokCtrl.text = ServerConfig.isCustom ? ServerConfig.baseUrl : '';
  }

  // Tap the 📖 logo 5 times to reveal the ngrok panel
  void _onLogoTap() {
    _logoTapCount++;
    if (_logoTapCount >= 5) {
      _logoTapCount = 0;
      setState(() => _showNgrokPanel = !_showNgrokPanel);
    }
  }

  Future<void> _testAndSaveNgrokUrl() async {
    final url = _ngrokCtrl.text.trim();
    if (url.isEmpty) {
      await ServerConfig.clear();
      setState(() { _ngrokStatus = '✅ Reset to default LAN server'; _showNgrokPanel = false; });
      return;
    }
    setState(() { _ngrokTesting = true; _ngrokStatus = null; });
    try {
      final uri = Uri.parse('$url/api/health');
      final r = await http.get(uri, headers: {'ngrok-skip-browser-warning': 'true'}).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        await ServerConfig.setUrl(url);
        setState(() { _ngrokStatus = '✅ Connected! Server is live.'; _showNgrokPanel = false; });
      } else {
        setState(() => _ngrokStatus = '❌ Server replied ${r.statusCode}');
      }
    } catch (e) {
      setState(() => _ngrokStatus = '❌ Can\'t reach server — check the URL');
    } finally {
      if (mounted) setState(() => _ngrokTesting = false);
    }
  }

  Widget _buildNgrokPanel(BuildContext ctx) => AnimatedSize(
    duration: const Duration(milliseconds: 300),
    child: _showNgrokPanel ? DoodleCard(
      color: kAccent.withOpacity(0.12),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🔗', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Text('Server URL',
              style: GoogleFonts.nunito(fontWeight: FontWeight.w800,
                  fontSize: 15, color: kAccent)),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() => _showNgrokPanel = false),
            child: const Icon(Icons.close, size: 18, color: Colors.white54)),
        ]),
        const SizedBox(height: 10),
        TextField(
          controller: _ngrokCtrl,
          style: GoogleFonts.nunito(fontSize: 13, color: kText(ctx)),
          decoration: InputDecoration(
            hintText: 'https://xxxx.ngrok-free.app',
            hintStyle: GoogleFonts.nunito(color: kSub(ctx), fontSize: 12),
            filled: true,
            fillColor: kBg(ctx),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            suffixIcon: ServerConfig.isCustom
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18, color: kPrimary),
                    onPressed: () async {
                      _ngrokCtrl.clear();
                      await ServerConfig.clear();
                      setState(() => _ngrokStatus = '✅ Reset to default');
                    })
                : null,
          ),
        ),
        if (_ngrokStatus != null) ...[
          const SizedBox(height: 6),
          Text(_ngrokStatus!,
              style: GoogleFonts.nunito(fontSize: 12,
                  color: _ngrokStatus!.startsWith('✅') ? kGreen : kPrimary)),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: _ngrokTesting
              ? const Center(child: SizedBox(height: 24, width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)))
              : DoodleButton(
                  label: 'Connect',
                  color: kAccent,
                  icon: Icons.cable_rounded,
                  wide: true,
                  onTap: _testAndSaveNgrokUrl),
        ),
        if (ServerConfig.isCustom) ...[
          const SizedBox(height: 6),
          Center(child: Text('Active: ${ServerConfig.baseUrl}',
              style: GoogleFonts.nunito(fontSize: 11, color: kAccent,
                  fontWeight: FontWeight.w700))),
        ],
      ]),
    ) : const SizedBox.shrink(),
  );

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });
    try {
      Map<String, dynamic> res;
      if (_isLogin) {
        res = await Api.post('/api/auth/login', {
          'email': _emailCtrl.text.trim(), 'password': _passCtrl.text});
      } else {
        res = await Api.post('/api/auth/signup', {
          'name': _nameCtrl.text.trim(),
          'email': _emailCtrl.text.trim(), 'password': _passCtrl.text});
      }
      await Api.saveToken(res['token']);
      final p = await SharedPreferences.getInstance();
      await p.setString('user_name', res['name']);
      if (!mounted) return;
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const MainNav()));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override void dispose() {
    _bgCtrl.dispose(); _nameCtrl.dispose();
    _emailCtrl.dispose(); _passCtrl.dispose();
    _ngrokCtrl.dispose(); super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: AnimatedBuilder(
          animation: _bgCtrl,
          builder: (_, child) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [
                  Color.lerp(kPrimary, kPurple, _bgCtrl.value)!,
                  Color.lerp(kSecondary, kAccent, _bgCtrl.value)!,
                ],
              ),
            ),
            child: child,
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                const SizedBox(height: 40),
                GestureDetector(
                  onTap: _onLogoTap,
                  child: const Text('📖', style: TextStyle(fontSize: 64))),
                Text('VibeStory', style: GoogleFonts.pacifico(fontSize: 38, color: Colors.white)),
                const SizedBox(height: 8),
                Text(_isLogin ? 'Welcome back! 👋' : 'Join the adventure! 🌟',
                    style: GoogleFonts.nunito(color: Colors.white70, fontSize: 16)),
                const SizedBox(height: 16),
                _buildNgrokPanel(context),
                const SizedBox(height: 20),
                DoodleCard(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    if (!_isLogin) ...[
                      _Field(ctrl: _nameCtrl, label: 'Your Name', icon: Icons.face_retouching_natural),
                      const SizedBox(height: 14),
                    ],
                    _Field(ctrl: _emailCtrl, label: 'Email', icon: Icons.email_rounded,
                        keyboard: TextInputType.emailAddress),
                    const SizedBox(height: 14),
                    _Field(ctrl: _passCtrl, label: 'Password', icon: Icons.lock_rounded, obscure: true),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: kPrimary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12)),
                        child: Text(_error!, style: const TextStyle(color: kPrimary, fontSize: 13)),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _loading
                        ? const CircularProgressIndicator()
                        : DoodleButton(
                            label: _isLogin ? 'Let\'s Go! 🚀' : 'Create Account ✨',
                            onTap: _submit, wide: true),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () => setState(() => _isLogin = !_isLogin),
                      child: Text(
                        _isLogin ? 'New here? Create an account →'
                                 : 'Already have an account? Login →',
                        style: GoogleFonts.nunito(color: kPrimary,
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboard;
  const _Field({required this.ctrl, required this.label, required this.icon,
      this.obscure = false, this.keyboard});
  @override
  Widget build(BuildContext context) => TextField(
        controller: ctrl, obscureText: obscure, keyboardType: keyboard,
        style: GoogleFonts.nunito(fontSize: 15, color: kText(context)),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: kPrimary),
          filled: true,
          fillColor: kBg(context),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: kPrimary, width: 2)),
        ),
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  MAIN NAVIGATION
// ════════════════════════════════════════════════════════════════════════════
class MainNav extends StatefulWidget {
  const MainNav({super.key});
  @override State<MainNav> createState() => _MainNavState();
}

class _MainNavState extends State<MainNav> {
  int _idx = 0;
  final _pages = const [HomeScreen(), LearnScreen(), ProfileScreen()];

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg(context),
        body: IndexedStack(index: _idx, children: _pages),
        bottomNavigationBar: Container(
          height: 70,
          decoration: BoxDecoration(
            color: kCard(context),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.1),
                  blurRadius: 12, offset: const Offset(0, -2))
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Expanded(child: _NavItem(icon: Icons.home_rounded, label: 'Home',
                    idx: 0, sel: _idx, onTap: () => setState(() => _idx = 0))),
                Expanded(child: _NavItem(icon: Icons.search_rounded, label: 'Learn',
                    idx: 1, sel: _idx, onTap: () => setState(() => _idx = 1))),
                Expanded(child: _NavItem(icon: Icons.person_rounded, label: 'Profile',
                    idx: 2, sel: _idx, onTap: () => setState(() => _idx = 2))),
              ],
            ),
          ),
        ),
      );
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int idx, sel;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label,
      required this.idx, required this.sel, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final active = idx == sel;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: active ? kPrimary.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: active ? 26 : 22, color: active ? kPrimary : kSub(context)),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.nunito(
              fontSize: 11,
              color: active ? kPrimary : kSub(context),
              fontWeight: active ? FontWeight.w800 : FontWeight.w600)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  HOME SCREEN
// ════════════════════════════════════════════════════════════════════════════
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _textCtrl  = TextEditingController();
  final _recorder  = AudioRecorder();
  bool _recording  = false;
  bool _loading    = false;
  String? _transcript, _rawText, _lang, _error;

  @override void dispose() { _textCtrl.dispose(); _recorder.dispose(); super.dispose(); }

  Future<void> _toggleRecord() async {
    final perm = await Permission.microphone.request();
    if (!perm.isGranted) return;
    if (_recording) {
      final path = await _recorder.stop();
      setState(() { _recording = false; });
      if (path != null) await _sendAudio(path);
    } else {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/vibestory_rec.m4a';
      await _recorder.start(const RecordConfig(), path: path);
      setState(() { _recording = true; _transcript = null; _error = null; });
    }
  }

  Future<void> _pickAudio() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _sendAudio(path);
  }

  Future<void> _sendAudio(String filePath) async {
    setState(() { _loading = true; _error = null; _transcript = null; });
    try {
      final res = await Api.uploadAudio('/api/input/transcribe', filePath);
      setState(() {
        _transcript = res['english']; _rawText = res['original'];
        _lang = res['language']; _textCtrl.text = _transcript ?? '';
      });
    } catch (e) { setState(() => _error = e.toString()); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _translateTyped() async {
    if (_textCtrl.text.trim().isEmpty) return;
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Api.post('/api/input/translate', {'text': _textCtrl.text.trim()});
      setState(() { _transcript = res['english']; _textCtrl.text = _transcript ?? ''; });
    } catch (e) { setState(() => _error = e.toString()); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _submit() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) { setState(() => _error = 'Please write or record your story idea!'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Api.post('/api/story/generate', {'text': text});
      if (!mounted) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => StoryGeneratingScreen(storyId: res['story_id'])));
    } catch (e) { setState(() => _error = e.toString()); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('✨', style: TextStyle(fontSize: 28)),
              const SizedBox(width: 8),
              Text('VibeStory',
                  style: GoogleFonts.pacifico(fontSize: 28, color: kPrimary)),
            ]),
            const SizedBox(height: 24),
            DoodleCard(
              color: kPrimary.withOpacity(0.08),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Share your story! 📝',
                    style: GoogleFonts.nunito(
                        fontSize: 20, fontWeight: FontWeight.w900, color: kPrimary)),
                const SizedBox(height: 4),
                Text('Tell us something that happened to you, or make up a magical adventure!',
                    style: GoogleFonts.nunito(fontSize: 14, color: kSub(context))),
              ]),
            ),
            const SizedBox(height: 20),
            DoodleCard(
              child: Column(children: [
                TextField(
                  controller: _textCtrl, maxLines: 5,
                  style: GoogleFonts.nunito(fontSize: 15, color: kText(context)),
                  decoration: InputDecoration(
                    hintText: 'Once upon a time… (Hindi, Punjabi or English!)',
                    hintStyle: GoogleFonts.nunito(color: kSub(context), fontSize: 14),
                    border: InputBorder.none,
                  ),
                ),
                const Divider(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _loading ? null : _translateTyped,
                    icon: const Icon(Icons.translate, color: kAccent),
                    label: Text('Translate to English',
                        style: GoogleFonts.nunito(color: kAccent, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            Text('Or use your voice:',
                style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 15, color: kText(context))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: DoodleButton(
                  label: _recording ? 'Stop ⏹' : 'Record 🎙',
                  color: _recording ? kPrimary : kAccent,
                  icon: _recording ? Icons.stop : Icons.mic,
                  onTap: _loading ? null : _toggleRecord)),
              const SizedBox(width: 12),
              Expanded(child: DoodleButton(
                  label: 'Upload 📂', color: kPurple, icon: Icons.upload_file,
                  onTap: _loading ? null : _pickAudio)),
            ]),
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(children: [
                  const _PulseCircle(),
                  const SizedBox(width: 8),
                  Text('Recording… tap Stop when done',
                      style: GoogleFonts.nunito(color: kPrimary, fontWeight: FontWeight.w700)),
                ]),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_lang != null && _lang != 'en' && _transcript != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DoodleCard(
                  color: kAccent.withOpacity(0.1),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Detected: $_lang → Translated ✅',
                        style: GoogleFonts.nunito(color: kAccent, fontWeight: FontWeight.w800)),
                    if (_rawText != null) ...[
                      const SizedBox(height: 4),
                      Text('Original: $_rawText',
                          style: GoogleFonts.nunito(color: kSub(context), fontSize: 13)),
                    ],
                  ]),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DoodleCard(
                  color: kPrimary.withOpacity(0.1),
                  child: Text(_error!, style: GoogleFonts.nunito(color: kPrimary, fontSize: 14)),
                ),
              ),
            const SizedBox(height: 28),
            DoodleButton(
              label: 'Make My Story! 🚀',
              onTap: _loading || _recording ? null : _submit,
              wide: true, color: kPrimary, icon: Icons.auto_stories,
            ),
            const SizedBox(height: 40),
          ]),
        ),
      );
}

class _PulseCircle extends StatefulWidget {
  const _PulseCircle();
  @override State<_PulseCircle> createState() => _PulseCircleState();
}
class _PulseCircleState extends State<_PulseCircle> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: 600.ms)..repeat(reverse: true);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Container(
          width: 14, height: 14,
          decoration: BoxDecoration(
            color: Color.lerp(kPrimary, Colors.red.shade300, _c.value),
            shape: BoxShape.circle,
          ),
        ),
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  STORY GENERATING SCREEN
// ════════════════════════════════════════════════════════════════════════════
class StoryGeneratingScreen extends StatefulWidget {
  final String storyId;
  const StoryGeneratingScreen({super.key, required this.storyId});
  @override State<StoryGeneratingScreen> createState() => _StoryGeneratingScreenState();
}

class _StoryGeneratingScreenState extends State<StoryGeneratingScreen> {
  Timer? _poll;
  String _status = 'queued', _step = 'Starting up… 🔥';
  List<String> _images = [];
  String? _audioUrl;
  bool _done = false;
  String? _error;

  // Dev mode
  final List<Map<String, dynamic>> _devLogs = [];
  final Map<int, int> _imgProgress = {}; // part → step

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    if (AppState().devMode) _startDevStream();
  }

  void _startDevStream() {
    // Poll dev log from story status (dev_log field)
    // SSE is complex in Flutter, so we fetch from status which includes dev_log
  }

  Future<void> _tick() async {
    try {
      final res = await Api.get('/api/story/${widget.storyId}/status');
      if (!mounted) return;
      setState(() {
        _status  = res['status'] ?? 'running';
        _step    = res['step'] ?? '';
        _images  = List<String>.from(res['images'] ?? []);
        _audioUrl= res['audio_url'];
        if (AppState().devMode) {
          final logs = List<Map<String, dynamic>>.from(res['dev_log'] ?? []);
          _devLogs.clear();
          _devLogs.addAll(logs);
        }
      });
      if (_status == 'done') { _poll?.cancel(); setState(() => _done = true); }
      else if (_status == 'error') { _poll?.cancel(); setState(() => _error = _step); }
    } catch (_) {}
  }

  @override void dispose() { _poll?.cancel(); super.dispose(); }

  Widget _buildDevPanel() {
    if (_devLogs.isEmpty) return const SizedBox();
    return DoodleCard(
      color: Colors.black87,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('🛠 Dev Log', style: GoogleFonts.sourceCodePro(
            color: kAccent, fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: ListView.builder(
            itemCount: _devLogs.length,
            itemBuilder: (_, i) {
              final e = _devLogs[_devLogs.length - 1 - i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('▶ ${e['msg']}',
                      style: GoogleFonts.sourceCodePro(color: Colors.greenAccent, fontSize: 11)),
                  if (e['data'] != null)
                    Text(const JsonEncoder.withIndent('  ').convert(e['data']).substring(
                        0, min(200, const JsonEncoder.withIndent('  ').convert(e['data']).length)),
                        style: GoogleFonts.sourceCodePro(
                            color: Colors.white54, fontSize: 9)),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg(context),
        appBar: AppBar(
          backgroundColor: kBg(context), elevation: 0,
          title: Text('Making your story…',
              style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: kText(context))),
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: kText(context)),
            onPressed: () => Navigator.pop(context)),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: kText(context)),
              onPressed: _tick,
              tooltip: 'Refresh',
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              DoodleCard(
                color: kSecondary.withOpacity(0.3),
                child: Row(children: [
                  const Text('⚙️', style: TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_step,
                      style: GoogleFonts.nunito(
                          fontSize: 16, fontWeight: FontWeight.w700, color: kText(context)))),
                  if (!_done && _error == null)
                    const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: kPrimary)),
                ]),
              ),
              const SizedBox(height: 12),
              _StepChips(imageCount: _images.length),
              const SizedBox(height: 12),
              if (AppState().devMode) ...[
                _buildDevPanel(),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: _images.isEmpty
                    ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Text('🎨', style: TextStyle(fontSize: 64)),
                        const SizedBox(height: 12),
                        Text('The magic is brewing…',
                            style: GoogleFonts.nunito(color: kSub(context), fontSize: 16)),
                      ]))
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12),
                        itemCount: _images.length,
                        itemBuilder: (_, i) => ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.network(
                            '${ServerConfig.baseUrl}${_images[i]}', fit: BoxFit.cover,
                            loadingBuilder: (_, child, prog) =>
                                prog == null ? child : const Center(child: CircularProgressIndicator()),
                          ),
                        ),
                      ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                DoodleCard(color: kPrimary.withOpacity(0.1),
                    child: Text('Oops! $_error', style: GoogleFonts.nunito(color: kPrimary))),
              ],
              if (_done) ...[
                const SizedBox(height: 16),
                DoodleCard(
                  color: kGreen.withOpacity(0.15),
                  child: Row(children: [
                    const Text('🎉', style: TextStyle(fontSize: 28)),
                    const SizedBox(width: 12),
                    Text('Your story is ready!',
                        style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w800, color: kGreen)),
                  ]),
                ),
                const SizedBox(height: 12),
                DoodleButton(
                  label: '▶ Play My Story',
                  wide: true, color: kGreen, icon: Icons.play_circle_fill_rounded,
                  onTap: () => Navigator.pushReplacement(context,
                      MaterialPageRoute(builder: (_) => StoryPlayScreen(
                          storyId: widget.storyId,
                          images: _images,
                          audioUrl: _audioUrl ?? ''))),
                ),
              ],
            ]),
          ),
        ),
      );
}

class _StepChips extends StatelessWidget {
  final int imageCount;
  const _StepChips({required this.imageCount});
  @override
  Widget build(BuildContext context) {
    final steps = [
      ('✨ Story', true),
      ('🖼 Images', imageCount > 0),
      ('🎙 Audio', imageCount >= 5),
      ('🎉 Done', false),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: steps.map((s) => _Chip(label: s.$1, done: s.$2)).toList(),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label; final bool done;
  const _Chip({required this.label, required this.done});
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: 300.ms,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: done ? kGreen.withOpacity(0.15) : kBg(context),
          border: Border.all(color: done ? kGreen : kSub(context).withOpacity(0.3)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: GoogleFonts.nunito(
            fontSize: 12, color: done ? kGreen : kSub(context),
            fontWeight: done ? FontWeight.w800 : FontWeight.w600)),
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  STORY PLAY SCREEN  — AUDIO FIX
// ════════════════════════════════════════════════════════════════════════════
class StoryPlayScreen extends StatefulWidget {
  final String storyId, audioUrl;
  final List<String> images;
  const StoryPlayScreen({super.key, required this.storyId,
      required this.images, required this.audioUrl});
  @override State<StoryPlayScreen> createState() => _StoryPlayScreenState();
}

class _StoryPlayScreenState extends State<StoryPlayScreen> {
  final _player = AudioPlayer();
  int _imgIdx  = 0;
  bool _playing= false;
  bool _loading= false;
  Duration _pos= Duration.zero, _dur = Duration.zero;
  String? _audioError;

  @override
  void initState() {
    super.initState();
    _player.setReleaseMode(ReleaseMode.stop);
    _player.onDurationChanged.listen((d) { if (mounted) setState(() => _dur = d); });
    _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() {
        _pos = p;
        if (_dur.inMilliseconds > 0 && widget.images.isNotEmpty) {
          final frac = p.inMilliseconds / _dur.inMilliseconds;
          _imgIdx = (frac * widget.images.length).floor().clamp(0, widget.images.length - 1);
        }
      });
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _playing = false; _imgIdx = 0; });
    });
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _loading = s == PlayerState.playing ? false : _loading);
    });
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }

    if (widget.audioUrl.isEmpty) {
      setState(() => _audioError = 'Audio not available for this story.');
      return;
    }

    final url = '${ServerConfig.baseUrl}${widget.audioUrl}';
    setState(() { _loading = true; _audioError = null; });
    try {
      if (_pos == Duration.zero || _pos >= _dur) {
        // Fresh play — always set source explicitly
        await _player.stop();
        await _player.setSourceUrl(url);
        await _player.resume();
      } else {
        await _player.resume();
      }
      setState(() => _playing = true);
    } catch (e) {
      setState(() => _audioError = 'Cannot play audio: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _seekTo(double frac) async {
    final ms = (frac * _dur.inMilliseconds).round();
    await _player.seek(Duration(milliseconds: ms));
  }

  @override void dispose() { _player.dispose(); super.dispose(); }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white),
        title: Text('Your Story 📖', style: GoogleFonts.pacifico(color: Colors.white)),
        actions: [
          if (AppState().devMode)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                backgroundColor: Colors.white12,
                label: Text(widget.audioUrl.isNotEmpty ? widget.audioUrl.split('/').last : 'no audio',
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: imgs.isEmpty
                ? const Center(child: Text('🖼️', style: TextStyle(fontSize: 64)))
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 600),
                    child: Image.network(
                      '${ServerConfig.baseUrl}${imgs[_imgIdx]}',
                      key: ValueKey(_imgIdx),
                      width: double.infinity, fit: BoxFit.contain,
                    ),
                  ),
          ),
          // Dot indicators
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(imgs.length, (i) => AnimatedContainer(
                    duration: 300.ms,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _imgIdx ? 18 : 8, height: 8,
                    decoration: BoxDecoration(
                      color: i == _imgIdx ? kSecondary : Colors.white30,
                      borderRadius: BorderRadius.circular(4)),
                  )),
            ),
          ),
          if (_audioError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_audioError!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  textAlign: TextAlign.center),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            color: Colors.black,
            child: Column(children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: kSecondary, inactiveTrackColor: Colors.white24,
                  thumbColor: kSecondary),
                child: Slider(
                  value: _dur.inMilliseconds == 0
                      ? 0 : (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0),
                  onChanged: _dur.inMilliseconds > 0 ? _seekTo : null,
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(_fmt(_pos), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                Text(_fmt(_dur), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ]),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70, size: 32),
                  onPressed: () => setState(() =>
                      _imgIdx = (_imgIdx - 1).clamp(0, imgs.length - 1))),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: _loading ? null : _togglePlay,
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: kPrimary, shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: kPrimary.withOpacity(0.5), blurRadius: 16)],
                    ),
                    child: _loading
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                        : Icon(
                            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white, size: 36),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, color: Colors.white70, size: 32),
                  onPressed: () => setState(() =>
                      _imgIdx = (_imgIdx + 1).clamp(0, imgs.length - 1))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  LEARN SCREEN
// ════════════════════════════════════════════════════════════════════════════
class LearnScreen extends StatefulWidget {
  const LearnScreen({super.key});
  @override State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  List<Map<String, dynamic>> _stories = [];
  bool _loading = true;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Api.get('/api/profile');
      setState(() { _stories = List<Map<String, dynamic>>.from(res['stories'] ?? []); });
    } catch (_) {}
    finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('🔍', style: TextStyle(fontSize: 28)),
              const SizedBox(width: 8),
              Text('Learn', style: GoogleFonts.pacifico(fontSize: 28, color: kAccent)),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.refresh_rounded, color: kText(context)),
                onPressed: _load, tooltip: 'Refresh'),
            ]),
            Text('Tap an image and find what\'s inside! 🧐',
                style: GoogleFonts.nunito(color: kSub(context), fontSize: 14)),
            const SizedBox(height: 20),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _stories.isEmpty
                      ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          const Text('📚', style: TextStyle(fontSize: 60)),
                          const SizedBox(height: 12),
                          Text('Make a story first to start learning!',
                              style: GoogleFonts.nunito(color: kSub(context), fontSize: 15),
                              textAlign: TextAlign.center),
                        ]))
                      : _buildGrid(context),
            ),
          ]),
        ),
      );

  Widget _buildGrid(BuildContext context) {
    final storyImgs = _stories
        .expand<Map<String, dynamic>>((s) =>
            List<String>.from(s['images'] ?? []).map((img) => {'img': img, 'sid': s['_id']}))
        .toList();
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12),
      itemCount: storyImgs.length,
      itemBuilder: (ctx, i) {
        final item = storyImgs[i];
        return GestureDetector(
          onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) =>
              LearnImageScreen(imageUrl: item['img'], storyId: item['sid'], imageIndex: i))),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(fit: StackFit.expand, children: [
              Image.network('${ServerConfig.baseUrl}${item['img']}', fit: BoxFit.cover),
              Positioned(bottom: 0, left: 0, right: 0,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  color: Colors.black54,
                  child: Text('Tap to explore! 🔍',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.nunito(
                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  LEARN IMAGE SCREEN
// ════════════════════════════════════════════════════════════════════════════
class LearnImageScreen extends StatefulWidget {
  final String imageUrl, storyId;
  final int imageIndex;
  const LearnImageScreen({super.key, required this.imageUrl,
      required this.storyId, required this.imageIndex});
  @override State<LearnImageScreen> createState() => _LearnImageScreenState();
}

class _UserBox {
  Offset start, end; String label;
  _UserBox({required this.start, required this.end, this.label = ''});
  Rect get rect => Rect.fromPoints(start, end);
}

class _LearnImageScreenState extends State<LearnImageScreen> {
  List<Map<String, dynamic>> _yoloDets = [];
  bool _detectLoading = false, _showYolo = false, _drawMode = false, _submitted = false;
  Offset? _drawStart, _drawCurrent;
  List<_UserBox> _userBoxes = [];
  final GlobalKey _imgKey = GlobalKey();
  static const double _imgNatW = 512, _imgNatH = 512;

  Future<void> _runYolo() async {
    setState(() { _detectLoading = true; _showYolo = false; });
    try {
      final r = await http.get(Uri.parse('${ServerConfig.baseUrl}${widget.imageUrl}'),
          headers: {'Authorization': 'Bearer ${Api._token}'});
      final res = await Api.uploadImageBytes('/api/learn/detect', r.bodyBytes, 'image.jpg');
      setState(() { _yoloDets = List<Map<String, dynamic>>.from(res['detections'] ?? []); _showYolo = true; });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Detection failed: $e')));
    } finally { if (mounted) setState(() => _detectLoading = false); }
  }

  Future<void> _submitLabels() async {
    if (_userBoxes.isEmpty || _userBoxes.any((b) => b.label.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please label all your boxes first!')));
      return;
    }
    final sz = (_imgKey.currentContext?.findRenderObject() as RenderBox?)?.size;
    final labels = _userBoxes.map((b) {
      final r = b.rect;
      final scaleX = _imgNatW / (sz?.width ?? _imgNatW);
      final scaleY = _imgNatH / (sz?.height ?? _imgNatH);
      return {
        'label': b.label,
        'box': {
          'x': (r.left * scaleX).round(), 'y': (r.top * scaleY).round(),
          'width': (r.width * scaleX).round(), 'height': (r.height * scaleY).round(),
        }
      };
    }).toList();
    try {
      final res = await Api.post('/api/learn/submit-labels', {
        'story_id': widget.storyId,
        'image_index': widget.imageIndex,
        'image_url': widget.imageUrl,
        'labels': labels,
      });
      setState(() => _submitted = true);
      if (mounted) showDialog(context: context, builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Text('🎉 Amazing!', style: GoogleFonts.pacifico(color: kPrimary)),
            content: Text(
                'You found ${_userBoxes.length} things!\n'
                '+${res['points_awarded']} points\nTotal: ${res['new_score']} ⭐',
                style: GoogleFonts.nunito(fontSize: 15)),
            actions: [DoodleButton(label: 'Awesome!', onTap: () => Navigator.pop(context))],
          ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Submit failed: $e')));
    }
  }

  void _onPanStart(DragStartDetails d) {
    if (!_drawMode) return;
    final box = _imgKey.currentContext!.findRenderObject() as RenderBox;
    setState(() => _drawStart = box.globalToLocal(d.globalPosition));
  }
  void _onPanUpdate(DragUpdateDetails d) {
    if (!_drawMode || _drawStart == null) return;
    final box = _imgKey.currentContext!.findRenderObject() as RenderBox;
    setState(() => _drawCurrent = box.globalToLocal(d.globalPosition));
  }
  void _onPanEnd(DragEndDetails _) {
    if (!_drawMode || _drawStart == null || _drawCurrent == null) return;
    final nb = _UserBox(start: _drawStart!, end: _drawCurrent!);
    setState(() { _userBoxes.add(nb); _drawStart = null; _drawCurrent = null; });
    _promptLabel(_userBoxes.length - 1);
  }

  void _promptLabel(int idx) {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('What did you find? 🤔',
              style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: kText(context))),
          content: TextField(controller: ctrl, autofocus: true,
              decoration: InputDecoration(
                  hintText: 'e.g. tree, cat, house…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
          actions: [DoodleButton(label: 'Done ✅',
              onTap: () { setState(() => _userBoxes[idx].label = ctrl.text.trim()); Navigator.pop(context); })],
        ));
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: kBg(context),
      appBar: AppBar(
        backgroundColor: kBg(context), elevation: 0,
        iconTheme: IconThemeData(color: kText(context)),
        title: Text('Explore the Picture!',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: kText(context))),
      ),
      body: SafeArea(
        child: SingleChildScrollView(child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DoodleCard(
              color: kPurple.withOpacity(0.12),
              child: Text(
                _drawMode
                    ? 'Draw a box around things you can name! 🎯'
                    : 'Tap "AI Detect" to see what AI found, then draw your own boxes!',
                style: GoogleFonts.nunito(color: kPurple, fontWeight: FontWeight.w700, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          GestureDetector(
            onPanStart: _onPanStart, onPanUpdate: _onPanUpdate, onPanEnd: _onPanEnd,
            child: SizedBox(width: screenW, height: screenW,
              child: Stack(children: [
                Positioned.fill(child: Image.network(
                    '${ServerConfig.baseUrl}${widget.imageUrl}', key: _imgKey, fit: BoxFit.contain)),
                if (_showYolo) ..._yoloDets.map((d) {
                  final b = d['box'] as Map;
                  final sx = screenW / _imgNatW, sy = screenW / _imgNatH;
                  return Positioned(
                    left: (b['x'] as int) * sx, top: (b['y'] as int) * sy,
                    width: (b['width'] as int) * sx, height: (b['height'] as int) * sy,
                    child: Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: kAccent, width: 2.5),
                          borderRadius: BorderRadius.circular(6)),
                      child: Align(alignment: Alignment.topLeft,
                        child: Container(color: kAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Text('${d['label']} ${(d['confidence'] * 100).round()}%',
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))),
                    ),
                  );
                }),
                ..._userBoxes.asMap().entries.map((e) {
                  final r = e.value.rect;
                  return Positioned(left: r.left, top: r.top, width: r.width, height: r.height,
                    child: GestureDetector(
                      onTap: () => _promptLabel(e.key),
                      child: Container(
                        decoration: BoxDecoration(
                            border: Border.all(color: kPrimary, width: 2.5, style: BorderStyle.solid),
                            borderRadius: BorderRadius.circular(6),
                            color: kPrimary.withOpacity(0.08)),
                        child: Align(alignment: Alignment.topLeft,
                          child: Container(color: kPrimary,
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Text(e.value.label.isEmpty ? 'Tap to label' : e.value.label,
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))),
                      ),
                    ),
                  );
                }),
                if (_drawStart != null && _drawCurrent != null)
                  Positioned(
                    left: min(_drawStart!.dx, _drawCurrent!.dx),
                    top: min(_drawStart!.dy, _drawCurrent!.dy),
                    width: (_drawStart!.dx - _drawCurrent!.dx).abs(),
                    height: (_drawStart!.dy - _drawCurrent!.dy).abs(),
                    child: Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: kSecondary, width: 2),
                          color: kSecondary.withOpacity(0.1))),
                  ),
              ]),
            ),
          ),
          if (_userBoxes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: DoodleCard(
                color: kSecondary.withOpacity(0.2),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Text('⭐', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 8),
                  Text('You found ${_userBoxes.length} thing${_userBoxes.length == 1 ? '' : 's'}!',
                      style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 16, color: kText(context))),
                ]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              DoodleButton(
                label: _detectLoading ? 'Detecting…'
                    : _showYolo ? 'AI Found ${_yoloDets.length} Things!'
                    : 'AI Detect 🔍',
                color: kAccent, icon: Icons.search_rounded, wide: true,
                onTap: _detectLoading ? null : _runYolo),
              const SizedBox(height: 12),
              DoodleButton(
                label: _drawMode ? 'Drawing Mode ON (tap to stop)' : 'Draw Your Own Boxes ✏️',
                color: _drawMode ? kPrimary : kPurple, icon: _drawMode ? Icons.stop : Icons.draw_rounded,
                wide: true, onTap: () => setState(() => _drawMode = !_drawMode)),
              if (_userBoxes.isNotEmpty) ...[
                const SizedBox(height: 12),
                DoodleButton(
                    label: 'Submit My Labels ✅', color: kGreen,
                    icon: Icons.check_circle_rounded, wide: true,
                    onTap: _submitted ? null : _submitLabels),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _userBoxes.clear()),
                  icon: const Icon(Icons.delete_rounded, color: kPrimary),
                  label: Text('Clear boxes',
                      style: GoogleFonts.nunito(color: kPrimary, fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
          ),
        ])),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  PROFILE SCREEN
// ════════════════════════════════════════════════════════════════════════════
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Api.get('/api/profile');
      setState(() { _profile = res; });
    } catch (_) {}
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _logout() async {
    await Api.clearToken();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context,
        MaterialPageRoute(builder: (_) => const AuthScreen()), (_) => false);
  }

  String _badge(int score) {
    if (score >= 1000) return '🏆 Legend Explorer';
    if (score >= 500)  return '🥇 Super Finder';
    if (score >= 200)  return '🥈 Object Hunter';
    if (score >= 50)   return '🥉 Curious Learner';
    return '🌱 Story Seedling';
  }

  @override
  Widget build(BuildContext context) {
    final profile  = _profile;
    final score    = profile?['score'] as int? ?? 0;
    final objects  = profile?['total_objects'] as int? ?? 0;
    final stories  = List<Map<String, dynamic>>.from(profile?['stories'] ?? []);

    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('👤', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 8),
            Text('Profile', style: GoogleFonts.pacifico(fontSize: 28, color: kPurple)),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: kText(context)),
              onPressed: _load, tooltip: 'Refresh'),
            IconButton(
              icon: Icon(Icons.settings_rounded, color: kText(context)),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen())).then((_) => setState(() {})),
              tooltip: 'Settings'),
          ]),
          const SizedBox(height: 20),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else ...[
            DoodleCard(
              color: kPurple.withOpacity(0.1),
              child: Row(children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: kPurple.withOpacity(0.2),
                  child: Text(
                    (profile?['name'] as String? ?? 'U').substring(0, 1).toUpperCase(),
                    style: GoogleFonts.pacifico(fontSize: 28, color: kPurple)),
                ),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(profile?['name'] ?? 'Explorer',
                      style: GoogleFonts.nunito(
                          fontSize: 20, fontWeight: FontWeight.w900, color: kText(context))),
                  const SizedBox(height: 4),
                  Text(_badge(score),
                      style: GoogleFonts.nunito(
                          fontSize: 14, color: kPurple, fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
            const SizedBox(height: 16),
            DoodleCard(
              color: kSecondary.withOpacity(0.2),
              child: Column(children: [
                Text('⭐ Your Score',
                    style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 15, color: kText(context))),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _ScoreStat(emoji: '🏅', label: 'Points', value: '$score'),
                  _ScoreStat(emoji: '🔍', label: 'Objects Found', value: '$objects'),
                  _ScoreStat(emoji: '📖', label: 'Stories', value: '${stories.length}'),
                ]),
                const SizedBox(height: 12),
                _BadgeProgress(score: score),
              ]),
            ),
            const SizedBox(height: 20),
            Text('📚 My Stories',
                style: GoogleFonts.nunito(fontWeight: FontWeight.w900, fontSize: 18, color: kText(context))),
            const SizedBox(height: 12),
            if (stories.isEmpty)
              DoodleCard(child: Center(child: Text('No stories yet! Make your first one 🎉',
                  style: GoogleFonts.nunito(color: kSub(context), fontSize: 14))))
            else ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: stories.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (ctx, i) {
                final s    = stories[i];
                final imgs = List<String>.from(s['images'] ?? []);
                final preview = s['refined_story'] as String? ?? '';
                return GestureDetector(
                  onTap: () {
                    if (imgs.isEmpty) return;
                    Navigator.push(ctx, MaterialPageRoute(builder: (_) =>
                        StoryPlayScreen(storyId: s['_id'], images: imgs,
                            audioUrl: s['audio_url'] ?? '')));
                  },
                  child: DoodleCard(
                    child: Row(children: [
                      if (imgs.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network('${ServerConfig.baseUrl}${imgs[0]}',
                              width: 72, height: 72, fit: BoxFit.cover)),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(preview.length > 80 ? '${preview.substring(0, 80)}…' : preview,
                            style: GoogleFonts.nunito(fontSize: 13, color: kText(context))),
                        const SizedBox(height: 4),
                        Row(children: [
                          const Icon(Icons.play_circle_rounded, color: kPrimary, size: 16),
                          const SizedBox(width: 4),
                          Text('Play again',
                              style: GoogleFonts.nunito(
                                  color: kPrimary, fontWeight: FontWeight.w700, fontSize: 12)),
                        ]),
                      ])),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 40),
          ],
        ]),
      ),
    );
  }
}

class _ScoreStat extends StatelessWidget {
  final String emoji, label, value;
  const _ScoreStat({required this.emoji, required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(emoji, style: const TextStyle(fontSize: 26)),
        Text(value, style: GoogleFonts.nunito(fontWeight: FontWeight.w900, fontSize: 20, color: kText(context))),
        Text(label, style: GoogleFonts.nunito(color: kSub(context), fontSize: 11)),
      ]);
}

class _BadgeProgress extends StatelessWidget {
  final int score;
  const _BadgeProgress({required this.score});
  @override
  Widget build(BuildContext context) {
    const thresholds = [0, 50, 200, 500, 1000];
    int nextIdx = thresholds.indexWhere((t) => score < t);
    if (nextIdx == -1) nextIdx = thresholds.length - 1;
    final prev = thresholds[(nextIdx - 1).clamp(0, thresholds.length - 1)];
    final next = thresholds[nextIdx];
    final pct  = next == prev ? 1.0 : (score - prev) / (next - prev);
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('$score pts', style: GoogleFonts.nunito(fontSize: 12, color: kSub(context))),
        Text('$next pts to next badge', style: GoogleFonts.nunito(fontSize: 12, color: kSub(context))),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          value: pct.clamp(0.0, 1.0), minHeight: 10,
          backgroundColor: Colors.white54,
          valueColor: const AlwaysStoppedAnimation(kPurple)),
      ),
    ]);
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  SETTINGS SCREEN
// ════════════════════════════════════════════════════════════════════════════
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _appState = AppState();
  Map<String, dynamic>? _devConfig;
  bool _configLoading = false;
  late int _imageSteps;
  late String _voice;
  final _voices = ['af_heart','af_bella','af_sarah','am_adam','am_michael','bf_emma','bm_george'];

  @override
  void initState() {
    super.initState();
    _imageSteps = 5;
    _voice = 'af_heart';
    if (_appState.devMode) _loadDevConfig();
  }

  Future<void> _loadDevConfig() async {
    setState(() => _configLoading = true);
    try {
      final res = await Api.get('/api/dev/config');
      setState(() {
        _devConfig = res;
        _imageSteps = res['image_steps'] ?? 5;
        _voice      = res['kokoro_voice'] ?? 'af_heart';
      });
    } catch (_) {}
    finally { if (mounted) setState(() => _configLoading = false); }
  }

  Future<void> _saveDevConfig() async {
    try {
      await Api.post('/api/dev/config', {
        'image_steps': _imageSteps,
        'kokoro_voice': _voice,
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dev settings saved ✓')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _logout() async {
    await Api.clearToken();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context,
        MaterialPageRoute(builder: (_) => const AuthScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg(context),
        appBar: AppBar(
          backgroundColor: kBg(context), elevation: 0,
          iconTheme: IconThemeData(color: kText(context)),
          title: Text('Settings ⚙️',
              style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: kText(context))),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // ── Theme ──────────────────────────────────────────────────────
              _SectionHeader('🎨 Appearance'),
              const SizedBox(height: 12),
              DoodleCard(
                child: Column(children: [
                  _ThemeRow(
                    label: 'System (follow device)',
                    icon: Icons.phone_android_rounded,
                    selected: _appState.themeMode == ThemeMode.system,
                    onTap: () => _appState.setTheme(ThemeMode.system).then((_) => setState(() {})),
                  ),
                  const Divider(height: 1),
                  _ThemeRow(
                    label: 'Light',
                    icon: Icons.light_mode_rounded,
                    selected: _appState.themeMode == ThemeMode.light,
                    onTap: () => _appState.setTheme(ThemeMode.light).then((_) => setState(() {})),
                  ),
                  const Divider(height: 1),
                  _ThemeRow(
                    label: 'Dark',
                    icon: Icons.dark_mode_rounded,
                    selected: _appState.themeMode == ThemeMode.dark,
                    onTap: () => _appState.setTheme(ThemeMode.dark).then((_) => setState(() {})),
                  ),
                ]),
              ),
              const SizedBox(height: 24),

              // ── Dev Mode toggle ────────────────────────────────────────────
              _SectionHeader('🛠 Developer Mode'),
              const SizedBox(height: 12),
              DoodleCard(
                child: Column(children: [
                  Row(children: [
                    Icon(Icons.developer_mode_rounded,
                        color: _appState.devMode ? kAccent : kSub(context)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Dev Mode', style: GoogleFonts.nunito(
                          fontWeight: FontWeight.w800, fontSize: 16, color: kText(context))),
                      Text('Show AI pipeline details, prompts, model info',
                          style: GoogleFonts.nunito(color: kSub(context), fontSize: 12)),
                    ])),
                    Switch(
                      value: _appState.devMode,
                      activeColor: kAccent,
                      onChanged: (v) {
                        _appState.setDevMode(v).then((_) {
                          setState(() {});
                          if (v) _loadDevConfig();
                        });
                      },
                    ),
                  ]),
                ]),
              ),

              if (_appState.devMode) ...[
                const SizedBox(height: 16),
                _configLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _devConfig == null
                        ? DoodleCard(child: Text('Could not load config from server.',
                            style: GoogleFonts.nunito(color: kSub(context))))
                        : DoodleCard(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Model Info', style: GoogleFonts.nunito(
                                  fontWeight: FontWeight.w900, color: kText(context), fontSize: 15)),
                              const SizedBox(height: 10),
                              _InfoRow('Whisper', _devConfig!['whisper_model'] ?? '-'),
                              _InfoRow('LLM', _devConfig!['qwen_model'] ?? '-'),
                              _InfoRow('Image', _devConfig!['image_model'] ?? '-'),
                              _InfoRow('TTS Voice', _devConfig!['kokoro_voice'] ?? '-'),
                              _InfoRow('Device', _devConfig!['device_name'] ?? '-'),
                              _InfoRow('CUDA', _devConfig!['cuda_available'] == true ? 'Yes ✓' : 'No (CPU)'),
                              const Divider(height: 24),
                              Text('Edit Settings', style: GoogleFonts.nunito(
                                  fontWeight: FontWeight.w900, color: kText(context), fontSize: 15)),
                              const SizedBox(height: 12),
                              // Image steps slider
                              Row(children: [
                                Icon(Icons.photo_filter_rounded, color: kPurple, size: 20),
                                const SizedBox(width: 8),
                                Text('Image Steps: $_imageSteps',
                                    style: GoogleFonts.nunito(color: kText(context), fontWeight: FontWeight.w700)),
                              ]),
                              Slider(
                                value: _imageSteps.toDouble(),
                                min: 1, max: 50, divisions: 49,
                                activeColor: kPurple,
                                label: '$_imageSteps steps',
                                onChanged: (v) => setState(() => _imageSteps = v.round()),
                              ),
                              Text('Lower = faster, Higher = better quality',
                                  style: GoogleFonts.nunito(color: kSub(context), fontSize: 11)),
                              const SizedBox(height: 16),
                              // Voice picker
                              Row(children: [
                                const Icon(Icons.record_voice_over_rounded, color: kAccent, size: 20),
                                const SizedBox(width: 8),
                                Text('TTS Voice',
                                    style: GoogleFonts.nunito(color: kText(context), fontWeight: FontWeight.w700)),
                              ]),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                value: _voices.contains(_voice) ? _voice : _voices.first,
                                decoration: InputDecoration(
                                  filled: true, fillColor: kBg(context),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                ),
                                items: _voices.map((v) => DropdownMenuItem(value: v, child: Text(v,
                                    style: GoogleFonts.nunito()))).toList(),
                                onChanged: (v) { if (v != null) setState(() => _voice = v); },
                              ),
                              const SizedBox(height: 16),
                              DoodleButton(
                                  label: 'Save Dev Settings', color: kAccent,
                                  icon: Icons.save_rounded, wide: true,
                                  onTap: _saveDevConfig),
                            ]),
                          ),
              ],

              const SizedBox(height: 24),

              // ── Logout ─────────────────────────────────────────────────────
              _SectionHeader('Account'),
              const SizedBox(height: 12),
              DoodleButton(
                label: 'Logout', color: kPrimary,
                icon: Icons.logout_rounded, wide: true,
                onTap: _logout),
              const SizedBox(height: 40),
            ]),
          ),
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: GoogleFonts.nunito(
          fontWeight: FontWeight.w900, fontSize: 16, color: kSub(context)));
}

class _ThemeRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeRow({required this.label, required this.icon, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: selected ? kPrimary : kSub(context)),
        title: Text(label, style: GoogleFonts.nunito(
            color: kText(context), fontWeight: selected ? FontWeight.w800 : FontWeight.w500)),
        trailing: selected ? const Icon(Icons.check_circle_rounded, color: kPrimary) : null,
        onTap: onTap,
      );
}

class _InfoRow extends StatelessWidget {
  final String label, value;    
  const _InfoRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text('$label: ',         
              style: GoogleFonts.nunito(color: kSub(context), fontSize: 12)),
          Flexible(child: Text(value,
              style: GoogleFonts.nunito(
                  color: kText(context), fontWeight: FontWeight.w700, fontSize: 12))),
        ]),
      );
}