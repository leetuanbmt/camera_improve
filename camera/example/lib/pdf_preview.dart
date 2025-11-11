import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_combiner/models/pdf_from_multiple_image_config.dart';
import 'package:pdf_combiner/pdf_combiner.dart';
import 'package:pdf_combiner/responses/pdf_combiner_status.dart';
import 'package:pdfx/pdfx.dart';

import 'logger.dart';

class PdfPreview extends StatefulWidget {
  const PdfPreview({super.key, required this.imagePath});
  final String imagePath;

  @override
  State<PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<PdfPreview> {
  late final PdfController pdfController;
  @override
  void initState() {
    super.initState();
    pdfController = PdfController(
      document: _createPdfFromImage(),
    );
  }

  Future<PdfDocument> _createPdfFromImage() async {
    try {
      final name = '${DateTime.now().millisecondsSinceEpoch}.pdf';
      final tempDir = await getApplicationDocumentsDirectory();
      final pdfPath = '${tempDir.path}/$name';
      Logger.log('pdf $pdfPath');

      // Create PDF directly (not in isolate since PdfCombiner uses platform channels)
      final response = await PdfCombiner.createPDFFromMultipleImages(
        inputPaths: [widget.imagePath],
        outputPath: pdfPath,
        config: PdfFromMultipleImageConfig(),
      );

      if (response.status == PdfCombinerStatus.success) {
        Logger.log('PDF creation completed successfully');
      } else {
        final errorMsg = response.message?.isNotEmpty ?? false
            ? response.message!
            : 'PDF creation failed with no message.';
        Logger.log('Error PDF creation failed: $errorMsg');
        throw Exception(errorMsg);
      }
      return PdfDocument.openFile(response.outputPath);
    } catch (e) {
      Logger.log('Error in _createPdfFromImage: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('PDF Preview'),
      ),
      body: PdfView(
        controller: pdfController,
      ),
    );
  }
}
