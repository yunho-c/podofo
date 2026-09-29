import 'package:flutter/material.dart' show Icons, Tooltip;
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Tooltip;

class AudioReaderButton extends StatelessWidget {
  const AudioReaderButton({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Audio reader',
    child: IconButton(
      icon: const Icon(Icons.volume_up_outlined),
      enabled: false,
      variance: ButtonStyle.ghostIcon(),
    ),
  );
}
