import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import 'package:podofo_one/src/data/open_graph_data.dart';

/// Fetches and parses Open Graph metadata from a given URL.
///
/// Returns an OpenGraphData object. Returns an empty one if fetching or parsing fails, or if no Open Graph data is found.
Future<OpenGraphData> fetchOpenGraphData(String url) async {
  final Map<String, String> openGraphMap = {};

  if (url.isEmpty) {
    print('URL is empty, cannot fetch Open Graph data.');
    return OpenGraphData();
  }

  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final document = html_parser.parse(response.body);
      final metaTags = document.querySelectorAll('meta');

      for (final tag in metaTags) {
        // Check for 'property' attribute and if it starts with 'og:'
        if (tag.attributes.containsKey('property') &&
            tag.attributes['property']!.startsWith('og:')) {
          final propertyName = tag.attributes['property']!;
          final content = tag.attributes['content'];
          if (content != null) {
            openGraphMap[propertyName] = content;
          }
        }
        // Sometimes og:image might be in itemprop, though less common for pure OG
        else if (tag.attributes.containsKey('itemprop') &&
            tag.attributes['itemprop'] == 'image' &&
            tag.attributes['content'] != null) {
          // This is not a standard OG tag, but for broader compatibility, we can include it
          // Prefacing with a distinct key to avoid collision if og:image also exists
          if (!openGraphMap.containsKey('custom_og_image')) {
            // Only add if no og:image exists
            openGraphMap['custom_og_image'] = tag.attributes['content']!;
          }
        }
      }
    } else {
      print('Failed to load URL: $url with status code ${response.statusCode}');
    }
  } catch (e) {
    print('Error fetching or parsing Open Graph data for $url: $e');
  }

  return OpenGraphData.fromMap(openGraphMap);
}
