class OpenGraphData {
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;
  final String? url;
  final String? type;

  OpenGraphData({
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
    this.url,
    this.type,
  });

  factory OpenGraphData.fromMap(Map<String, String> map) {
    return OpenGraphData(
      title: map['og:title'],
      description: map['og:description'],
      imageUrl: map['og:image'] ?? map['custom_og_image'],
      siteName: map['og:site_name'],
      url: map['og:url'],
      type: map['og:type'],
    );
  }

  bool get isEmpty =>
      title == null &&
      description == null &&
      imageUrl == null &&
      siteName == null &&
      url == null &&
      type == null;
}
