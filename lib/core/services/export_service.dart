import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../features/reports/report_providers.dart';

/// Export format selector.
enum ExportFormat { excel, pdf }

/// Single-point export service. All methods are static — no state, no DI needed.
class ExportService {
  ExportService._();

  // ─── Colour tokens ─────────────────────────────────────────────────────────

  static final _headerFill = ExcelColor.fromHexString('#1565C0');
  static final _altRowFill = ExcelColor.fromHexString('#E3F2FD');

  static const PdfColor _pdfBlue = PdfColor.fromInt(0xFF1565C0);
  static const PdfColor _pdfLightBlue = PdfColor.fromInt(0xFFE3F2FD);
  static const PdfColor _pdfWhite = PdfColors.white;

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Production Report — daily rows.
  static Future<void> exportProductionReport({
    required BuildContext context,
    required List<DailyProductionRow> rows,
    required String fromDate,
    required String toDate,
    required ExportFormat format,
  }) async {
    const title = 'Production Report';
    final subtitle = '$fromDate  →  $toDate';
    const headers = [
      'Date',
      'Total Production',
      'BP Reject',
      'Good Qty',
      'Target',
      'Efficiency %',
      'Reject %',
    ];
    final data = rows
        .map((r) => [
              r.date,
              _fmt(r.totalProduction),
              _fmt(r.bpReject),
              _fmt(r.goodQty),
              _fmt(r.target),
              '${r.efficiency.toStringAsFixed(1)}%',
              '${r.rejectPct.toStringAsFixed(1)}%',
            ],)
        .toList();

    final totalProd = rows.fold(0.0, (s, r) => s + r.totalProduction);
    final totalReject = rows.fold(0.0, (s, r) => s + r.bpReject);
    final totalGood = rows.fold(0.0, (s, r) => s + r.goodQty);
    final summary = [
      'TOTAL',
      _fmt(totalProd),
      _fmt(totalReject),
      _fmt(totalGood),
      '—',
      totalProd > 0 ? '${(totalGood / totalProd * 100).toStringAsFixed(1)}%' : '—',
      totalProd > 0 ? '${(totalReject / totalProd * 100).toStringAsFixed(1)}%' : '—',
    ];

    if (format == ExportFormat.excel) {
      final bytes = _buildExcel(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      if (!context.mounted) return;
      await _shareFile(
        context: context,
        bytes: bytes,
        filename: 'production_report_${fromDate}_$toDate.xlsx',
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    } else {
      final bytes = await _buildPdf(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      await _sharePdf(bytes: bytes, filename: 'production_report_${fromDate}_$toDate.pdf');
    }
  }

  /// Machine Downtime Report.
  static Future<void> exportDowntimeReport({
    required BuildContext context,
    required List<DowntimeRow> rows,
    required String fromDate,
    required String toDate,
    required ExportFormat format,
  }) async {
    const title = 'Machine Downtime Report';
    final subtitle = '$fromDate  →  $toDate';
    const headers = ['Date', 'Machine', 'Start Time', 'End Time', 'Duration (min)', 'Reason'];
    final data = rows
        .map((r) => [
              r.date,
              r.machineName,
              r.startTime,
              r.endTime ?? '—',
              r.durationMinutes.toString(),
              r.reason,
            ],)
        .toList();

    final totalMins = rows.fold(0, (s, r) => s + r.durationMinutes);
    final summary = ['TOTAL', '—', '—', '—', totalMins.toString(), '—'];

    if (format == ExportFormat.excel) {
      final bytes = _buildExcel(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      if (!context.mounted) return;
      await _shareFile(
        context: context,
        bytes: bytes,
        filename: 'downtime_report_${fromDate}_$toDate.xlsx',
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    } else {
      final bytes = await _buildPdf(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      await _sharePdf(bytes: bytes, filename: 'downtime_report_${fromDate}_$toDate.pdf');
    }
  }

  /// Stock Report — live stock per part.
  static Future<void> exportStockReport({
    required BuildContext context,
    required List<LiveStockRow> rows,
    required ExportFormat format,
  }) async {
    const title = 'Live Stock Report';
    final subtitle = 'Generated: ${DateTime.now().toString().substring(0, 16)}';
    const headers = [
      'Part Code',
      'Part Name',
      'Raw Material',
      'BP Stock',
      'BP Hold',
      'BP Rejected',
      'At Vendor',
      'Pending AP',
      'Approved AP',
      'AP Rejected',
      'RTV Stock',
      'RTV At Vendor',
      'Total Stock',
    ];
    final data = rows
        .map((r) => [
              r.partCode,
              r.partName,
              _fmt(r.rawMaterial),
              _fmt(r.bpStock),
              _fmt(r.bpHold),
              _fmt(r.bpRejected),
              _fmt(r.atFaco),
              _fmt(r.pendingAp),
              _fmt(r.approvedAp),
              _fmt(r.apRejected),
              _fmt(r.rtvStock),
              _fmt(r.rtvAtVendor),
              _fmt(r.totalStock),
            ],)
        .toList();

    final summary = [
      '—',
      'TOTAL',
      _fmt(rows.fold(0.0, (s, r) => s + r.rawMaterial)),
      _fmt(rows.fold(0.0, (s, r) => s + r.bpStock)),
      _fmt(rows.fold(0.0, (s, r) => s + r.bpHold)),
      _fmt(rows.fold(0.0, (s, r) => s + r.bpRejected)),
      _fmt(rows.fold(0.0, (s, r) => s + r.atFaco)),
      _fmt(rows.fold(0.0, (s, r) => s + r.pendingAp)),
      _fmt(rows.fold(0.0, (s, r) => s + r.approvedAp)),
      _fmt(rows.fold(0.0, (s, r) => s + r.apRejected)),
      _fmt(rows.fold(0.0, (s, r) => s + r.rtvStock)),
      _fmt(rows.fold(0.0, (s, r) => s + r.rtvAtVendor)),
      _fmt(rows.fold(0.0, (s, r) => s + r.totalStock)),
    ];

    if (format == ExportFormat.excel) {
      final bytes = _buildExcel(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      if (!context.mounted) return;
      await _shareFile(
        context: context,
        bytes: bytes,
        filename: 'stock_report.xlsx',
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    } else {
      final bytes = await _buildPdf(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      await _sharePdf(bytes: bytes, filename: 'stock_report.pdf');
    }
  }

  /// Quality / Reject Analysis Report.
  static Future<void> exportQualityReport({
    required BuildContext context,
    required List<RejectAnalysisRow> rows,
    required String fromDate,
    required String toDate,
    required ExportFormat format,
  }) async {
    const title = 'Quality / Reject Analysis Report';
    final subtitle = '$fromDate  →  $toDate';
    const headers = [
      'Date',
      'Part Name',
      'Production',
      'BP Reject',
      'AP Reject',
      'Total Reject',
      'Reject %',
    ];
    final data = rows
        .map((r) => [
              r.date,
              r.partName,
              _fmt(r.production),
              _fmt(r.bpReject),
              _fmt(r.apReject),
              _fmt(r.totalReject),
              '${r.rejectPct.toStringAsFixed(1)}%',
            ],)
        .toList();

    final totalProd = rows.fold(0.0, (s, r) => s + r.production);
    final totalBp = rows.fold(0.0, (s, r) => s + r.bpReject);
    final totalAp = rows.fold(0.0, (s, r) => s + r.apReject);
    final totalRej = rows.fold(0.0, (s, r) => s + r.totalReject);
    final summary = [
      'TOTAL',
      '—',
      _fmt(totalProd),
      _fmt(totalBp),
      _fmt(totalAp),
      _fmt(totalRej),
      totalProd > 0 ? '${(totalRej / totalProd * 100).toStringAsFixed(1)}%' : '—',
    ];

    if (format == ExportFormat.excel) {
      final bytes = _buildExcel(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      if (!context.mounted) return;
      await _shareFile(
        context: context,
        bytes: bytes,
        filename: 'quality_report_${fromDate}_$toDate.xlsx',
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    } else {
      final bytes = await _buildPdf(
        title: title,
        subtitle: subtitle,
        headers: headers,
        data: data,
        summaryRow: summary,
      );
      await _sharePdf(bytes: bytes, filename: 'quality_report_${fromDate}_$toDate.pdf');
    }
  }

  // ─── Excel Builder ─────────────────────────────────────────────────────────

  static Uint8List _buildExcel({
    required String title,
    required String subtitle,
    required List<String> headers,
    required List<List<String>> data,
    List<String>? summaryRow,
  }) {
    final excel = Excel.createExcel();
    final sheet = excel['Report'];
    excel.setDefaultSheet('Report');

    // ── Title row ──
    final titleCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0));
    titleCell.value = TextCellValue(title);
    titleCell.cellStyle = CellStyle(
      bold: true,
      fontSize: 14,
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
      backgroundColorHex: _headerFill,
    );
    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      CellIndex.indexByColumnRow(columnIndex: headers.length - 1, rowIndex: 0),
    );

    // ── Subtitle row ──
    final subCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1));
    subCell.value = TextCellValue(subtitle);
    subCell.cellStyle = CellStyle(
      italic: true,
      fontSize: 10,
      fontColorHex: ExcelColor.fromHexString('#555555'),
    );
    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1),
      CellIndex.indexByColumnRow(columnIndex: headers.length - 1, rowIndex: 1),
    );

    // ── Header row ──
    for (var col = 0; col < headers.length; col++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 3));
      cell.value = TextCellValue(headers[col]);
      cell.cellStyle = CellStyle(
        bold: true,
        fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
        backgroundColorHex: _headerFill,
        horizontalAlign: HorizontalAlign.Center,
      );
      sheet.setColumnWidth(col, 18);
    }

    // ── Data rows ──
    for (var rowIdx = 0; rowIdx < data.length; rowIdx++) {
      final isAlt = rowIdx.isOdd;
      final row = data[rowIdx];
      for (var col = 0; col < row.length; col++) {
        final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: rowIdx + 4));
        cell.value = TextCellValue(row[col]);
        if (isAlt) {
          cell.cellStyle = CellStyle(backgroundColorHex: _altRowFill);
        }
      }
    }

    // ── Summary row ──
    if (summaryRow != null) {
      final summaryRowIndex = data.length + 5;
      for (var col = 0; col < summaryRow.length; col++) {
        final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: summaryRowIndex));
        cell.value = TextCellValue(summaryRow[col]);
        cell.cellStyle = CellStyle(
          bold: true,
          backgroundColorHex: _headerFill,
          fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
        );
      }
    }

    // Remove default Sheet1 if still present
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    final encoded = excel.encode();
    return Uint8List.fromList(encoded!);
  }

  // ─── PDF Builder ───────────────────────────────────────────────────────────

  static Future<Uint8List> _buildPdf({
    required String title,
    required String subtitle,
    required List<String> headers,
    required List<List<String>> data,
    List<String>? summaryRow,
  }) async {
    final pdf = pw.Document();

    final font = pw.Font.helvetica();
    final fontBold = pw.Font.helveticaBold();
    final colCount = headers.length;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  title,
                  style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 16,
                    color: _pdfBlue,
                  ),
                ),
                pw.Text(
                  'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                  style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey600),
                ),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              subtitle,
              style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey700),
            ),
            pw.Divider(color: _pdfBlue, thickness: 1.5),
            pw.SizedBox(height: 4),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Text(
              'Generated by FactoryFlow ERP  •  ${DateTime.now().toString().substring(0, 16)}',
              style: pw.TextStyle(font: font, fontSize: 8, color: PdfColors.grey500),
            ),
          ],
        ),
        build: (ctx) {
          final tableRows = <pw.TableRow>[];

          // Header row
          tableRows.add(pw.TableRow(
            decoration: const pw.BoxDecoration(color: _pdfBlue),
            children: headers.map((h) => _pdfCell(h, fontBold, color: _pdfWhite, isHeader: true)).toList(),
          ),);

          // Data rows
          for (var i = 0; i < data.length; i++) {
            final isAlt = i.isOdd;
            tableRows.add(pw.TableRow(
              decoration: isAlt ? const pw.BoxDecoration(color: _pdfLightBlue) : null,
              children: data[i].map((cell) => _pdfCell(cell, font)).toList(),
            ),);
          }

          // Summary row
          if (summaryRow != null) {
            tableRows.add(pw.TableRow(
              decoration: pw.BoxDecoration(color: PdfColor.fromHex('#0D47A1')),
              children: summaryRow.map((s) => _pdfCell(s, fontBold, color: _pdfWhite)).toList(),
            ),);
          }

          return [
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.blueGrey200, width: 0.5),
              columnWidths: {for (var i = 0; i < colCount; i++) i: const pw.FlexColumnWidth(1)},
              children: tableRows,
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  static pw.Widget _pdfCell(
    String text,
    pw.Font font, {
    PdfColor? color,
    bool isHeader = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          font: font,
          fontSize: isHeader ? 8 : 7,
          color: color ?? PdfColors.black,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  // ─── Share helpers ─────────────────────────────────────────────────────────

  static Future<void> _shareFile({
    required BuildContext context,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType)],
        subject: filename,
      ),
    );
  }

  static Future<void> _sharePdf({
    required Uint8List bytes,
    required String filename,
  }) async {
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Bottom sheet that shows Excel / PDF export buttons.
/// Use [ExportSheet.show] to display it.
class ExportSheet extends StatelessWidget {
  const ExportSheet({super.key, required this.onExcel, required this.onPdf});

  final VoidCallback onExcel;
  final VoidCallback onPdf;

  static Future<void> show({
    required BuildContext context,
    required VoidCallback onExcel,
    required VoidCallback onPdf,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => ExportSheet(onExcel: onExcel, onPdf: onPdf),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Export Report',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.grid_on_rounded, color: Colors.green),
            ),
            title: const Text('Export as Excel (.xlsx)'),
            subtitle: const Text('Open in Excel, Google Sheets, etc.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              onExcel();
            },
          ),
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.picture_as_pdf_rounded, color: Colors.red),
            ),
            title: const Text('Export as PDF'),
            subtitle: const Text('Share via WhatsApp, Email, Drive, etc.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              onPdf();
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
