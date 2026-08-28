import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Dio configured so untrusted marketplace/addon URLs are connected through
/// the same public-address policy used during validation.
Dio createPinnedPublicHttpsDio(BaseOptions options) {
  final dio = Dio(options);
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: createPinnedPublicHttpsClient,
  );
  return dio;
}
