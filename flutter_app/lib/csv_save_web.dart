// Web implementation — uses dart:html to trigger browser download.
import 'dart:convert';
import 'dart:html' as html;

bool get isWebCsvSupported => true;

void saveCsvFile(String filename, String csvContent) {
  final bytes = utf8.encode(csvContent);
  final blob = html.Blob([bytes], 'text/csv');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
