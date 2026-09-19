package tetotv.fixture;

import eu.kanade.tachiyomi.source.model.FilterList;
import eu.kanade.tachiyomi.source.model.MangasPage;
import eu.kanade.tachiyomi.source.model.Page;
import eu.kanade.tachiyomi.source.model.SChapter;
import eu.kanade.tachiyomi.source.model.SManga;
import java.util.Collections;
import java.util.List;
import okhttp3.Request;
import rx.Observable;

/** DTOs are offline except the explicit, public example.com broker smoke. */
public final class OfflineFixtureMangaSource extends FixtureMangaSource {
    @Override public String getBaseUrl() { return "https://example.com"; }
    @Override public okhttp3.OkHttpClient getClient() {
        return super.getClient().newBuilder()
            .addInterceptor(chain -> chain.proceed(chain.request().newBuilder().tag(String.class, "fixture-rate-limit").build()))
            .addNetworkInterceptor(chain -> {
                if (chain.connection() != null || !"fixture-rate-limit".equals(chain.request().tag(String.class))) {
                    throw new AssertionError("Unsafe or incorrectly ordered network callback");
                }
                return chain.proceed(chain.request());
            }).build();
    }
    private SManga item() {
        SManga item = SManga.Companion.create();
        item.setUrl("/fixture"); item.setTitle("Generated offline manga"); return item;
    }
    @Override public Observable<MangasPage> fetchSearchManga(int page, String query, FilterList filters) {
        if (query.equals("broker")) return super.fetchSearchManga(page, query, filters);
        return Observable.just(new MangasPage(Collections.singletonList(item()), false));
    }
    @Override public Request popularMangaRequest(int page) {
        return new Request.Builder().url(getBaseUrl()).get().build();
    }
    @Override public Observable<SManga> fetchMangaDetails(SManga manga) { return Observable.just(item()); }
    @Override public Observable<List<SChapter>> fetchChapterList(SManga manga) {
        SChapter chapter = SChapter.Companion.create();
        chapter.setUrl("/chapter"); chapter.setName("Fixture chapter"); chapter.setChapter_number(1f);
        return Observable.just(Collections.singletonList(chapter));
    }
    @Override public Observable<List<Page>> fetchPageList(SChapter chapter) {
        return Observable.just(Collections.singletonList(new Page(0, "", "https://example.com/fixture.png", null)));
    }
}
