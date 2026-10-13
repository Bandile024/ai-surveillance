import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  SupabaseClient? client;

  if (supabaseUrl.isNotEmpty && publishableKey.isNotEmpty) {
    await Supabase.initialize(url: supabaseUrl, anonKey: publishableKey);
    client = Supabase.instance.client;
  }

  runApp(SentinelApp(client: client));
}

class SentinelApp extends StatelessWidget {
  const SentinelApp({super.key, required this.client});

  final SupabaseClient? client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sentinel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2488F5),
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF8FAFC),
          foregroundColor: Color(0xFF111827),
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: client == null
          ? const SetupRequiredScreen()
          : AuthenticationGate(client: client!),
    );
  }
}

class SetupRequiredScreen extends StatelessWidget {
  const SetupRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.shield_moon_outlined, size: 48),
                const SizedBox(height: 20),
                Text(
                  'Connect Sentinel to Supabase',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Run the app with your project URL and publishable key. '
                  'Do not use the service-role key here.',
                ),
                const SizedBox(height: 18),
                SelectableText(
                  'flutter run '
                  '--dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co '
                  '--dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AuthenticationGate extends StatelessWidget {
  const AuthenticationGate({super.key, required this.client});

  final SupabaseClient client;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      initialData: AuthState(
        AuthChangeEvent.initialSession,
        client.auth.currentSession,
      ),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text('Authentication error: ${snapshot.error}'),
            ),
          );
        }
        final session = snapshot.data?.session;
        if (session == null) {
          return SignInScreen(client: client);
        }
        return EventsDashboard(client: client);
      },
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.client});

  final SupabaseClient client;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _creatingAccount = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    try {
      if (_creatingAccount) {
        final response = await widget.client.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
        );
        if (response.session == null && mounted) {
          setState(() {
            _notice = 'Check your email to confirm your account, then sign in.';
          });
        }
      } else {
        await widget.client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not sign in: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 28),
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2488F5),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      size: 38,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    _creatingAccount ? 'Create your account' : 'Welcome back',
                    style: const TextStyle(
                      color: Color(0xFF111827),
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _creatingAccount
                        ? 'Sign up to access your security control center.'
                        : 'Log in to your security control center.',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 16,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 38),
                  const _AuthFieldLabel('Email'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _email,
                    decoration: _authInputDecoration(),
                    style: const TextStyle(color: Color(0xFF111827)),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    validator: (value) => value == null || !value.contains('@')
                        ? 'Enter a valid email address'
                        : null,
                  ),
                  const SizedBox(height: 24),
                  const _AuthFieldLabel('Password'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _password,
                    decoration: _authInputDecoration().copyWith(
                      suffixIcon: IconButton(
                        tooltip: _obscurePassword
                            ? 'Show password'
                            : 'Hide password',
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ),
                    style: const TextStyle(color: Color(0xFF111827)),
                    obscureText: _obscurePassword,
                    autofillHints: const [AutofillHints.password],
                    validator: (value) => value == null || value.length < 6
                        ? 'Use at least 6 characters'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFB42318),
                        fontSize: 14,
                      ),
                    ),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _notice!,
                      style: const TextStyle(
                        color: Color(0xFF147D54),
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 58,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1599F7), Color(0xFF2865E8)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x332865E8),
                            blurRadius: 16,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          disabledBackgroundColor: const Color(0xFF9ABBEF),
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _creatingAccount ? 'Register' : 'Login',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _creatingAccount = !_creatingAccount;
                            _error = null;
                            _notice = null;
                          }),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF2563EB),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 15,
                        ),
                        children: [
                          TextSpan(
                            text: _creatingAccount
                                ? 'Already have an account? '
                                : 'No account? ',
                          ),
                          TextSpan(
                            text: _creatingAccount ? 'Login' : 'Register',
                            style: const TextStyle(
                              color: Color(0xFF1677F2),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthFieldLabel extends StatelessWidget {
  const _AuthFieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: Color(0xFF111827),
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

InputDecoration _authInputDecoration() {
  return InputDecoration(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 19),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: Color(0xFFD7DEE7)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: Color(0xFFD7DEE7)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: Color(0xFF2488F5), width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: Color(0xFFB42318)),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: const BorderSide(color: Color(0xFFB42318), width: 1.5),
    ),
  );
}
