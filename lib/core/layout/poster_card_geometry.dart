/// Canonical geometry used by the default TV catalog poster grid.
///
/// Home's Modern Layout shelves use the same calculation so poster thumbnails
/// cannot quietly drift away from Search when either surface is tuned.
const double defaultPosterMaximumWidth = 150;
const double defaultPosterSpacing = 10;
const double defaultPosterHorizontalPadding = 8;
const double defaultPosterAspectRatio = .57;

({double width, double height}) defaultPosterCardGeometry(
  double availableWidth,
) {
  final gridWidth = (availableWidth - defaultPosterHorizontalPadding).clamp(
    0.0,
    double.infinity,
  );
  if (gridWidth <= 0) return (width: 0, height: 0);
  final calculatedCount =
      (gridWidth / (defaultPosterMaximumWidth + defaultPosterSpacing)).ceil();
  final count = calculatedCount < 1 ? 1 : calculatedCount;
  final width = (gridWidth - defaultPosterSpacing * (count - 1)) / count;
  return (width: width, height: width / defaultPosterAspectRatio);
}
