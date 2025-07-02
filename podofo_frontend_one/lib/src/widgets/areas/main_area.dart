import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/widgets/components/custom_pdf_viewer.dart';

class MainArea extends StatefulWidget {
  const MainArea({super.key});

  @override
  State<MainArea> createState() => _MainAreaState();
}

class _MainAreaState extends State<MainArea> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const CustomPdfViewer(),
        Positioned(
          top: 0,
          left: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovering = true),
            onExit: (_) => setState(() => _isHovering = false),
            child: Container(width: 50, height: 50, color: Colors.transparent),
          ),
        ),
        if (_isHovering)
          Positioned(
            top: 10,
            left: 10,
            child: IconButton(
              icon: const Icon(Icons.arrow_back_outlined),
              onPressed: () => {},
              variance: ButtonStyle.outlineIcon(),
            ),
          ),
      ],
    );
  }
}
