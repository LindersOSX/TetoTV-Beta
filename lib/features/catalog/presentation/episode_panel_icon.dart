import 'package:flutter/material.dart';

/// The lightweight, reference-matched symbols used by the episode action panel.
enum EpisodePanelGlyph {
  play,
  replay,
  previous,
  next,
  browse,
  add,
  skip,
  people,
}

class EpisodePanelIcon extends StatelessWidget {
  const EpisodePanelIcon({
    required this.glyph,
    this.size = 24,
    this.color,
    super.key,
  });

  final EpisodePanelGlyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final mirror =
        (glyph == EpisodePanelGlyph.previous ||
            glyph == EpisodePanelGlyph.next) &&
        Directionality.of(context) == TextDirection.rtl;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _EpisodePanelIconPainter(
            glyph: glyph,
            color:
                color ??
                IconTheme.of(context).color ??
                Theme.of(context).colorScheme.onSurface,
            mirror: mirror,
          ),
        ),
      ),
    );
  }
}

class _EpisodePanelIconPainter extends CustomPainter {
  const _EpisodePanelIconPainter({
    required this.glyph,
    required this.color,
    required this.mirror,
  });

  final EpisodePanelGlyph glyph;
  final Color color;
  final bool mirror;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    if (mirror) {
      canvas.translate(32, 0);
      canvas.scale(-1, 1);
    }

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (glyph) {
      case EpisodePanelGlyph.play:
        canvas.drawPath(
          Path()
            ..moveTo(5.8, 1.8)
            ..quadraticBezierTo(3.6, .5, 3.6, 3.1)
            ..lineTo(3.6, 28.9)
            ..quadraticBezierTo(3.6, 31.5, 5.8, 30.2)
            ..lineTo(28.1, 17.7)
            ..quadraticBezierTo(30.5, 16, 28.1, 14.3)
            ..close(),
          fill,
        );
      case EpisodePanelGlyph.replay:
        canvas.drawPath(
          Path()
            ..moveTo(4.6, 19.1)
            ..cubicTo(5.7, 26, 12.9, 30, 19.4, 27.6)
            ..cubicTo(26.1, 25.4, 29.1, 17.8, 25.5, 11.7)
            ..cubicTo(22.7, 7, 17.5, 5.5, 11.1, 7),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(7.4, 7.4)
            ..lineTo(14.2, 2.4)
            ..lineTo(13.2, 11.6)
            ..close(),
          fill,
        );
      case EpisodePanelGlyph.previous:
        canvas.drawPath(
          Path()
            ..moveTo(19.5, 8)
            ..lineTo(11.5, 16)
            ..lineTo(19.5, 24),
          stroke,
        );
      case EpisodePanelGlyph.next:
        canvas.drawPath(
          Path()
            ..moveTo(12.5, 8)
            ..lineTo(20.5, 16)
            ..lineTo(12.5, 24),
          stroke,
        );
      case EpisodePanelGlyph.browse:
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 8)
            ..lineTo(22.1, 8)
            ..moveTo(3.5, 16)
            ..lineTo(28.5, 16)
            ..moveTo(3.5, 24)
            ..lineTo(17.1, 24),
          stroke,
        );
        canvas.drawCircle(const Offset(23.5, 24), 1.4, fill);
      case EpisodePanelGlyph.add:
        canvas.drawPath(
          Path()
            ..moveTo(16, 4.8)
            ..lineTo(16, 27.2)
            ..moveTo(4.8, 16)
            ..lineTo(27.2, 16),
          stroke,
        );
      case EpisodePanelGlyph.skip:
        canvas.drawPath(
          Path()
            ..moveTo(7.1, 6.4)
            ..quadraticBezierTo(5.6, 5.5, 5.6, 7.5)
            ..lineTo(5.6, 24.5)
            ..quadraticBezierTo(5.6, 26.5, 7.1, 25.6)
            ..lineTo(21, 17.3)
            ..quadraticBezierTo(22.7, 16, 21, 14.7)
            ..close(),
          fill,
        );
        canvas.drawLine(
          const Offset(25.6, 6.5),
          const Offset(25.6, 25.5),
          stroke,
        );
      case EpisodePanelGlyph.people:
        canvas.drawCircle(const Offset(10.6, 10), 4.6, fill);
        canvas.drawCircle(const Offset(23.3, 10.4), 4.1, fill);
        canvas.drawPath(
          Path()
            ..moveTo(1.8, 27)
            ..lineTo(1.8, 24.3)
            ..cubicTo(1.8, 19.9, 5.6, 17.2, 10.6, 17.2)
            ..cubicTo(15.6, 17.2, 19.4, 19.9, 19.4, 24.3)
            ..lineTo(19.4, 27)
            ..close(),
          fill,
        );
        canvas.drawPath(
          Path()
            ..moveTo(21.8, 27)
            ..lineTo(21.8, 24.3)
            ..cubicTo(21.8, 21.8, 20.8, 19.6, 19, 17.9)
            ..cubicTo(20.3, 17.5, 21.7, 17.4, 23.3, 17.4)
            ..cubicTo(27.5, 17.4, 30.2, 20.3, 30.2, 24.2)
            ..lineTo(30.2, 27)
            ..close(),
          fill,
        );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EpisodePanelIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.mirror != mirror;
}
