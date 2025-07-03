String removePdfExtension(String text) {
  if (text.endsWith('.pdf')) {
    return text.substring(0, text.length - 4);
  }
  return text;
}
