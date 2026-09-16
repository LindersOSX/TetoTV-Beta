package dev.animetv.anime_tv.aniyomi;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.os.RemoteException;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Standalone test-APK process. Uses only Android/Java platform classes: the
 * target application's Kotlin runtime is not available to this classloader.
 */
public final class AniyomiHttpReplyTestService extends Service {
    @Override
    public IBinder onBind(Intent intent) {
        return new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                    throws RemoteException {
                if (code != IBinder.FIRST_CALL_TRANSACTION || reply == null) return false;
                require(data.dataSize() < 1024);
                try {
                    // Same production reply layout; this proves the descriptor
                    // crosses kernel Binder into an isolated UID, not just Parcel.
                    data.readException();
                    String text = data.readString();
                    require(text != null);
                    JSONObject metadata = new JSONObject(text);
                    int length = metadata.getInt("bodyLength");
                    require(length >= 0 && length <= 4 * 1024 * 1024);
                    require(data.readInt() == 1);
                    MessageDigest digest = MessageDigest.getInstance("SHA-256");
                    int total = 0;
                    try (ParcelFileDescriptor body = ParcelFileDescriptor.CREATOR.createFromParcel(data)) {
                        require(data.dataAvail() == 0 && body.getStatSize() == length);
                        require((Os.fcntlInt(body.getFileDescriptor(), OsConstants.F_GETFL, 0)
                                & OsConstants.O_ACCMODE) == OsConstants.O_RDONLY);
                        try (ParcelFileDescriptor.AutoCloseInputStream input =
                                new ParcelFileDescriptor.AutoCloseInputStream(body)) {
                            byte[] buffer = new byte[8192];
                            while (true) {
                                int count = input.read(buffer);
                                if (count < 0) break;
                                require(count <= length - total);
                                digest.update(buffer, 0, count);
                                total += count;
                            }
                        }
                    }
                    require(total == length);
                    reply.writeNoException();
                    reply.writeInt(Process.myUid());
                    reply.writeInt(total);
                    reply.writeByteArray(digest.digest());
                    return true;
                } catch (IOException | ErrnoException | NoSuchAlgorithmException | JSONException error) {
                    throw new IllegalStateException("http_body_fixture_failure", error);
                }
            }
        };
    }

    private static void require(boolean condition) {
        if (!condition) throw new IllegalArgumentException("http_body_fixture_invalid");
    }
}
