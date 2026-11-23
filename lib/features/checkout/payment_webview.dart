import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/config.dart';
import '../../core/theme.dart';

enum PaymentStatus { success, cancelled }

class PaymentResult {
  const PaymentResult(this.status, {this.sessionId});
  final PaymentStatus status;
  final String? sessionId;
}

/// Stripe Checkout inside the app. The backend's success/cancel URLs point at
/// the website (CLIENT_SITE_URL); the WebView intercepts them and closes,
/// so no deep-link setup is needed. Only Stripe and UK Stay Hub pages may load in
/// it – anything else (bank 3-D Secure apps, etc.) opens externally.
class PaymentWebView extends StatefulWidget {
  const PaymentWebView({super.key, required this.url});
  final String url;
  @override
  State<PaymentWebView> createState() => _PaymentWebViewState();
}

class _PaymentWebViewState extends State<PaymentWebView> {
  late final WebViewController _c;
  int _progress = 0;
  bool _done = false;

  bool _allowedHost(String host) =>
      host == 'checkout.stripe.com' ||
      host.endsWith('.stripe.com') ||
      host.endsWith('.stripe.network') ||
      host == 'js.stripe.com' ||
      host.endsWith('.hcaptcha.com') ||
      AppConfig.isSiteHost(host);

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => setState(() => _progress = p),
        onNavigationRequest: (req) {
          final uri = Uri.tryParse(req.url);
          if (uri == null) return NavigationDecision.prevent;
          final onSite = AppConfig.isSiteHost(uri.host);
          if (onSite && uri.path.contains('payment-success')) {
            _finish(PaymentResult(PaymentStatus.success, sessionId: uri.queryParameters['session_id']));
            return NavigationDecision.prevent;
          }
          if (onSite && uri.path.contains('payment-cancel')) {
            _finish(const PaymentResult(PaymentStatus.cancelled));
            return NavigationDecision.prevent;
          }
          if (uri.scheme != 'https' || !_allowedHost(uri.host)) {
            // Banking apps / wallets.
            launchUrl(uri, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  void _finish(PaymentResult r) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _finish(const PaymentResult(PaymentStatus.cancelled));
        },
        child: Scaffold(
          appBar: AppBar(
            title: Row(children: [
              const Icon(Icons.lock, size: 16, color: AppColors.green),
              const SizedBox(width: 6),
              Text('checkout.stripe.com', style: AppText.inter(size: 14, weight: FontWeight.w600)),
            ]),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => _finish(const PaymentResult(PaymentStatus.cancelled)),
            ),
            bottom: _progress < 100
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(2),
                    child: LinearProgressIndicator(value: _progress / 100, color: AppColors.green, minHeight: 2),
                  )
                : null,
          ),
          body: WebViewWidget(controller: _c),
        ),
      );
}
