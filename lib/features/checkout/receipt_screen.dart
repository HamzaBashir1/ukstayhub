import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/repo.dart';
import '../../widgets/common.dart';

/// The payment receipt PDF, shown inside the app. The share / print buttons in
/// the preview toolbar let the guest save it to Files, send it, or print it –
/// no browser involved.
class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({super.key, required this.reservationId});
  final String reservationId;

  /// Opens the receipt in-app. Use this everywhere a receipt is offered.
  static Future<void> open(BuildContext context, String reservationId) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(reservationId: reservationId)));

  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  late Future<Uint8List> _pdf = _load();

  Future<Uint8List> _load() async {
    final lang = ref.read(stringsProvider).lang;
    return Uint8List.fromList(await bookingRepo.receiptPdf(widget.reservationId, lang));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(title: Text(t('Receipt', 'Receipt'), style: AppText.inter(size: 16, weight: FontWeight.w700))),
      body: FutureBuilder<Uint8List>(
        future: _pdf,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorView(
              message: t('ReceiptLoadFailed', 'The receipt could not be loaded.'),
              error: snap.error,
              onRetry: () => setState(() => _pdf = _load()),
            );
          }
          if (!snap.hasData) return const LoadingView();
          return PdfPreview(
            build: (_) async => snap.data!,
            pdfFileName: 'ukstayhub-receipt-${widget.reservationId}.pdf',
            canChangeOrientation: false,
            canChangePageFormat: false,
            canDebug: false,
            allowPrinting: true,
            allowSharing: true,
          );
        },
      ),
    );
  }
}
