import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_studio_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TV focus defaults to the shared control radius', () {
    final control = TvFocusable(child: const SizedBox(), onPressed: () {});
    expect(control.borderRadius, BorderRadius.circular(TetoBoxStyle.radius));
  });

  testWidgets('studio controls use the shared surface and action order', (
    tester,
  ) async {
    var applied = false;
    final applyFocusNode = FocusNode();
    addTearDown(applyFocusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TetoStudioHeader(
                  title: 'Display Studio',
                  subtitle: 'Preview changes',
                  onBack: () {},
                ),
                const TetoStudioSectionTitle('Options'),
                const TetoStudioFocusSurface(
                  child: SizedBox(key: ValueKey('focus-card'), height: 48),
                ),
                const TetoStudioPreviewFrame(
                  key: ValueKey('preview-frame'),
                  child: SizedBox(height: 48),
                ),
                TetoStudioActions(
                  applyKey: const ValueKey('apply'),
                  resetKey: const ValueKey('reset'),
                  applyFocusNode: applyFocusNode,
                  onApply: () => applied = true,
                  onReset: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final preview = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('preview-frame')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (preview.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(TetoBoxStyle.radius),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('apply'))).dx,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('reset'))).dx),
    );
    await tester.tap(find.byKey(const ValueKey('apply')));
    expect(applied, isTrue);

    applyFocusNode.requestFocus();
    await tester.pumpAndSettle();
    final apply = tester.widget<FilledButton>(
      find.byKey(const ValueKey('apply')),
    );
    expect(
      apply.style!.overlayColor!.resolve({WidgetState.focused}),
      Colors.transparent,
    );
    final focusFrame = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('apply')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect((focusFrame.decoration as BoxDecoration).boxShadow, isNotEmpty);
  });
}
