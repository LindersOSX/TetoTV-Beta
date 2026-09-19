package tetotv.fixture;

import android.os.Process;
import app.cash.quickjs.QuickJs;
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList;
import eu.kanade.tachiyomi.animesource.model.AnimesPage;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.PropertyResourceBundle;
import java.net.InetSocketAddress;
import java.net.Socket;
import rx.Observable;

/** Generated first-party test code only: this class is never shipped in the application's runtime. */
public final class IsolationFixtureAnimeSource extends FixtureAnimeSource {
    @Override public Observable<java.util.List<eu.kanade.tachiyomi.animesource.model.Video>> fetchVideoList(
        eu.kanade.tachiyomi.animesource.model.SEpisode episode
    ) {
        return new FormatHintVideoSource().fetchVideoList(episode);
    }

    @Override public Observable<AnimesPage> fetchSearchAnime(int page, String query, AnimeFilterList filters) {
        // Same ClassLoader API used by extension-bundled Intl search/filter labels.
        try (InputStream stream = getClass().getClassLoader().getResourceAsStream("assets/i18n/messages_en.properties")) {
            if (stream == null) throw new AssertionError("Verified APK asset missing from DEX loader");
            PropertyResourceBundle labels = new PropertyResourceBundle(new InputStreamReader(stream, "UTF-8"));
            if (!"Fixture search".equals(labels.getString("search"))) throw new AssertionError("Wrong APK resource");
        } catch (java.io.IOException error) { throw new AssertionError("APK asset could not be read", error); }
        if (query.equals("failure-abi")) throw new NoSuchMethodError("generated-test-secret");
        if (query.equals("failure-capability")) throw new UnsupportedOperationException("generated-test-secret");
        if (query.equals("quickjs")) {
            try (QuickJs engine = QuickJs.create()) {
                Object result = engine.evaluate("'isolated-' + (6 * 7)");
                if (!"isolated-42".equals(result)) throw new AssertionError("QuickJS result mismatch");
            }
        }
        if (query.startsWith("isolation:")) {
            String[] parts = query.split(":", 3);
            if (Process.myUid() == Integer.parseInt(parts[1])) throw new AssertionError("Shared application UID");
            boolean fileDenied = false;
            try (FileInputStream ignored = new FileInputStream(parts[2])) {
                throw new AssertionError("Host-private sentinel was readable");
            } catch (java.io.IOException | SecurityException expected) { fileDenied = true; }
            boolean networkDenied = false;
            try (Socket socket = new Socket()) {
                socket.connect(new InetSocketAddress("1.1.1.1", 443), 1500);
            } catch (SecurityException expected) { networkDenied = true; }
            catch (java.io.IOException expected) {
                String message = String.valueOf(expected.getMessage()).toLowerCase();
                networkDenied = message.contains("permission denied") || message.contains("eacces") || message.contains("eperm");
            }
            if (!fileDenied || !networkDenied) throw new AssertionError("OS capability isolation failed");
        }
        if (query.equals("hang")) {
            while (true) { try { Thread.sleep(1000); } catch (InterruptedException ignored) {} }
        }
        return super.fetchSearchAnime(page, query, filters);
    }
}
