#include <jni.h>

#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <thread>

namespace {

constexpr std::uint64_t kApplicationId = 1536801401710055474ULL;
// This key must exactly match the Rich Presence asset configured for the
// TetoTV Discord application. Android launcher resources are not uploaded to
// Discord automatically.
constexpr auto kAppIconAssetKey = "tetotv_app_icon";
constexpr auto kCallbackInterval = std::chrono::milliseconds(16);

JavaVM* g_vm = nullptr;
jclass g_bridge_class = nullptr;
std::mutex g_bridge_mutex;

std::mutex g_command_mutex;
std::condition_variable g_command_cv;
std::queue<std::function<void()>> g_commands;
std::thread g_worker;
std::atomic<bool> g_running{false};
std::atomic<bool> g_ready{false};
std::atomic<std::uint64_t> g_auth_generation{0};
std::atomic<std::uint64_t> g_connection_generation{0};
std::unique_ptr<discordpp::Client> g_client;

struct Presence {
    std::string activity_kind;
    std::string title;
    int episode = 0;
    std::string chapter_label;
    int page = 0;
    int page_count = 0;
    bool playing = false;
    std::int64_t position_ms = 0;
    std::int64_t duration_ms = 0;
    std::string artwork_url;
};

std::optional<Presence> g_pending_presence;
std::optional<Presence> g_last_submitted_presence;
std::chrono::steady_clock::time_point g_last_presence_submission{};
bool g_presence_update_in_flight = false;
bool g_clear_presence_pending = false;
std::uint64_t g_presence_operation_generation = 0;
bool g_connection_requested = false;
bool g_manual_connect_after_token_update = false;
std::uint64_t g_token_ready_connection_generation = 0;

constexpr auto kPresenceTimelineTolerance = std::chrono::seconds(2);

std::string from_jstring(JNIEnv* env, jstring value) {
    if (value == nullptr) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) return {};
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

std::string safe_error(const discordpp::ClientResult& result) {
    std::string error = result.Error();
    if (error.empty()) error = result.ToString();
    for (char& value : error) {
        if (value == '\r' || value == '\n' || value == '\t') value = ' ';
    }
    if (error.size() > 240) error.resize(240);
    return error.empty() ? "Discord could not complete the request." : error;
}

bool succeeded(const discordpp::ClientResult& result) {
    return result.Type() == discordpp::ErrorType::None;
}

JNIEnv* current_env(bool* attached) {
    *attached = false;
    if (g_vm == nullptr) return nullptr;
    JNIEnv* env = nullptr;
    const jint status = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_OK) return env;
    if (status != JNI_EDETACHED) return nullptr;
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
    *attached = true;
    return env;
}

template <typename Callback>
void with_bridge(Callback callback) {
    bool attached = false;
    JNIEnv* env = current_env(&attached);
    if (env == nullptr) return;
    jclass bridge = nullptr;
    {
        std::scoped_lock lock(g_bridge_mutex);
        bridge = g_bridge_class;
    }
    if (bridge != nullptr) callback(env, bridge);
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) g_vm->DetachCurrentThread();
}

void notify_auth(const char* method,
                 bool success,
                 const std::string& access_token,
                 const std::string& refresh_token,
                 int token_type,
                 int expires_in,
                 const std::string& scopes,
                 const std::string& error) {
    with_bridge([&](JNIEnv* env, jclass bridge) {
        const jmethodID callback = env->GetStaticMethodID(
            bridge,
            method,
            "(ZLjava/lang/String;Ljava/lang/String;IILjava/lang/String;Ljava/lang/String;)V");
        if (callback == nullptr) return;
        jstring access = env->NewStringUTF(access_token.c_str());
        jstring refresh = env->NewStringUTF(refresh_token.c_str());
        jstring scope_value = env->NewStringUTF(scopes.c_str());
        jstring error_value = env->NewStringUTF(error.c_str());
        env->CallStaticVoidMethod(
            bridge,
            callback,
            success,
            access,
            refresh,
            token_type,
            expires_in,
            scope_value,
            error_value);
        env->DeleteLocalRef(access);
        env->DeleteLocalRef(refresh);
        env->DeleteLocalRef(scope_value);
        env->DeleteLocalRef(error_value);
    });
}

void notify_token_result(const char* method,
                         discordpp::ClientResult result,
                         std::string access_token,
                         std::string refresh_token,
                         discordpp::AuthorizationTokenType token_type,
                         std::int32_t expires_in,
                         std::string scopes) {
    const bool ok = succeeded(result);
    notify_auth(method,
                ok,
                ok ? access_token : std::string{},
                ok ? refresh_token : std::string{},
                static_cast<int>(token_type),
                ok ? expires_in : 0,
                ok ? scopes : std::string{},
                ok ? std::string{} : safe_error(result));
}

void notify_simple(const char* method, bool success, const std::string& error) {
    with_bridge([&](JNIEnv* env, jclass bridge) {
        const jmethodID callback =
            env->GetStaticMethodID(bridge, method, "(ZLjava/lang/String;)V");
        if (callback == nullptr) return;
        jstring error_value = env->NewStringUTF(error.c_str());
        env->CallStaticVoidMethod(bridge, callback, success, error_value);
        env->DeleteLocalRef(error_value);
    });
}

void notify_status(const std::string& status, const std::string& error = {}) {
    with_bridge([&](JNIEnv* env, jclass bridge) {
        const jmethodID callback = env->GetStaticMethodID(
            bridge, "onConnectionState", "(Ljava/lang/String;Ljava/lang/String;)V");
        if (callback == nullptr) return;
        jstring status_value = env->NewStringUTF(status.c_str());
        jstring error_value = env->NewStringUTF(error.c_str());
        env->CallStaticVoidMethod(bridge, callback, status_value, error_value);
        env->DeleteLocalRef(status_value);
        env->DeleteLocalRef(error_value);
    });
}

void post(std::function<void()> command) {
    {
        std::scoped_lock lock(g_command_mutex);
        g_commands.push(std::move(command));
    }
    g_command_cv.notify_one();
}

bool connect_pending_if_disconnected() {
    if (!g_client || !g_connection_requested ||
        !g_manual_connect_after_token_update ||
        g_token_ready_connection_generation != g_connection_generation.load() ||
        g_client->GetStatus() != discordpp::Client::Status::Disconnected) {
        return false;
    }
    // Consume the request before entering the SDK so a duplicate Disconnected
    // callback cannot open a second websocket.
    g_manual_connect_after_token_update = false;
    g_token_ready_connection_generation = 0;
    g_client->Connect();
    return true;
}

bool same_presence_timeline(const Presence& previous,
                            const Presence& next,
                            std::chrono::steady_clock::time_point now) {
    if (previous.activity_kind != next.activity_kind ||
        previous.title != next.title || previous.episode != next.episode ||
        previous.chapter_label != next.chapter_label ||
        previous.page != next.page || previous.page_count != next.page_count ||
        previous.playing != next.playing || previous.duration_ms != next.duration_ms ||
        previous.artwork_url != next.artwork_url) {
        return false;
    }
    if (!next.playing) return true;

    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                             now - g_last_presence_submission)
                             .count();
    const auto expected_position = previous.position_ms + elapsed;
    const auto delta = next.position_ms >= expected_position
                           ? next.position_ms - expected_position
                           : expected_position - next.position_ms;
    return delta <=
           std::chrono::duration_cast<std::chrono::milliseconds>(kPresenceTimelineTolerance)
               .count();
}

void flush_pending_presence();

void publish_presence(Presence value) {
    // Flutter updates Android's media session every few seconds and emits
    // back-to-back playing transitions while replacing a failed source. The
    // Discord SDK completes presence writes asynchronously on its websocket.
    // Retain only the newest desired state and never overlap those writes.
    g_clear_presence_pending = false;
    g_pending_presence = std::move(value);
    flush_pending_presence();
}

void flush_pending_presence() {
    if (!g_client || !g_ready.load() || g_presence_update_in_flight ||
        !g_pending_presence.has_value()) {
        return;
    }

    Presence value = std::move(*g_pending_presence);
    g_pending_presence.reset();
    const auto submitted_at = std::chrono::steady_clock::now();
    if (g_last_submitted_presence.has_value() &&
        same_presence_timeline(*g_last_submitted_presence, value, submitted_at)) {
        return;
    }

    discordpp::Activity activity;
    activity.SetType(discordpp::ActivityTypes::Watching);
    activity.SetStatusDisplayType(discordpp::StatusDisplayTypes::Details);
    activity.SetDetails(value.title);

    discordpp::ActivityAssets assets;
    if (!value.artwork_url.empty()) {
        assets.SetLargeImage(value.artwork_url);
        assets.SetLargeText(value.title);
        assets.SetSmallImage(std::string{kAppIconAssetKey});
        assets.SetSmallText(std::string{"TetoTV"});
    } else {
        assets.SetLargeImage(std::string{kAppIconAssetKey});
        assets.SetLargeText(std::string{"TetoTV"});
    }
    activity.SetAssets(std::move(assets));

    std::string state;
    if (value.activity_kind == "reading") {
        state = value.chapter_label.empty() ? "Reading" : value.chapter_label;
        if (value.page > 0) {
            state += " - Page " + std::to_string(value.page);
            if (value.page_count >= value.page) {
                state += " of " + std::to_string(value.page_count);
            }
        }
    } else {
        state = value.episode > 0 ? "Episode " + std::to_string(value.episode) : "Watching";
        state += value.playing ? " - Playing" : " - Paused";
    }
    activity.SetState(state);

    if (value.activity_kind != "reading" && value.playing && value.position_ms >= 0) {
        const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::system_clock::now().time_since_epoch())
                             .count();
        discordpp::ActivityTimestamps timestamps;
        timestamps.SetStart(static_cast<std::uint64_t>(now - value.position_ms));
        if (value.duration_ms > value.position_ms) {
            timestamps.SetEnd(
                static_cast<std::uint64_t>(now + value.duration_ms - value.position_ms));
        }
        activity.SetTimestamps(timestamps);
    }

    g_presence_update_in_flight = true;
    const auto presence_generation = ++g_presence_operation_generation;
    g_client->UpdateRichPresence(
        std::move(activity),
        [value = std::move(value), submitted_at, presence_generation](
            discordpp::ClientResult result) mutable {
            const bool ok = succeeded(result);
            std::string error = ok ? std::string{} : safe_error(result);
            // Return from the SDK callback before starting another SDK
            // operation. Some SDK callbacks may originate while its websocket
            // state machine is still unwinding.
            post([value = std::move(value),
                  submitted_at,
                  presence_generation,
                  ok,
                  error = std::move(error)]() mutable {
                if (presence_generation != g_presence_operation_generation) return;
                g_presence_update_in_flight = false;
                if (ok) {
                    g_last_submitted_presence = std::move(value);
                    g_last_presence_submission = submitted_at;
                }
                notify_simple("onPresenceResult", ok, error);
                if (g_clear_presence_pending) {
                    g_clear_presence_pending = false;
                    if (g_client && g_ready.load()) g_client->ClearRichPresence();
                    return;
                }
                flush_pending_presence();
            });
        });
}

void start_worker() {
    bool expected = false;
    if (!g_running.compare_exchange_strong(expected, true)) return;

    g_worker = std::thread([] {
        g_client = std::make_unique<discordpp::Client>();
        g_client->SetApplicationId(kApplicationId);
        g_client->SetStatusChangedCallback(
            [](discordpp::Client::Status status,
               discordpp::Client::Error error,
               std::int32_t error_detail) {
                post([status, error, error_detail] {
                    const bool ready = status == discordpp::Client::Status::Ready;
                    g_ready.store(ready);
                    switch (status) {
                        case discordpp::Client::Status::Ready:
                            g_connection_requested = false;
                            g_manual_connect_after_token_update = false;
                            g_token_ready_connection_generation = 0;
                            notify_status("ready");
                            flush_pending_presence();
                            break;
                        case discordpp::Client::Status::Connecting:
                        case discordpp::Client::Status::Connected:
                            notify_status("connecting");
                            break;
                        case discordpp::Client::Status::Reconnecting:
                        case discordpp::Client::Status::HttpWait:
                            notify_status("reconnecting");
                            break;
                        case discordpp::Client::Status::Disconnecting:
                            notify_status("disconnecting");
                            break;
                        case discordpp::Client::Status::Disconnected:
                            // The SDK guarantees all socket teardown is done at
                            // this status, so no prior presence write can still
                            // block a later clean connection.
                            ++g_presence_operation_generation;
                            g_presence_update_in_flight = false;
                            g_clear_presence_pending = false;
                            // A fresh socket needs a fresh activity publish;
                            // otherwise the timeline de-duplicator can mistake
                            // the last pre-disconnect state for a live one.
                            g_last_submitted_presence.reset();
                            if (g_connection_requested) {
                                if (!connect_pending_if_disconnected()) {
                                    // UpdateToken owns reconnecting a client
                                    // that was already connected. If teardown
                                    // won the race, its token callback will
                                    // return here once the new token is ready.
                                    notify_status("connecting");
                                }
                                break;
                            }
                            notify_status(
                                "disconnected",
                                error == discordpp::Client::Error::None
                                    ? std::string{}
                                    : "Discord disconnected (" +
                                          std::to_string(error_detail) + ").");
                            break;
                    }
                });
            });
        g_client->SetTokenExpirationCallback([] {
            post([] {
                with_bridge([](JNIEnv* env, jclass bridge) {
                    const jmethodID callback =
                        env->GetStaticMethodID(bridge, "onTokenExpiring", "()V");
                    if (callback != nullptr) env->CallStaticVoidMethod(bridge, callback);
                });
            });
        });

        while (g_running.load()) {
            std::queue<std::function<void()>> commands;
            {
                std::unique_lock lock(g_command_mutex);
                g_command_cv.wait_for(lock, kCallbackInterval, [] {
                    return !g_running.load() || !g_commands.empty();
                });
                std::swap(commands, g_commands);
            }
            while (!commands.empty()) {
                commands.front()();
                commands.pop();
            }
            discordpp::RunCallbacks();
        }

        if (g_client) {
            g_client->ClearRichPresence();
            g_client->Disconnect();
            discordpp::RunCallbacks();
            g_client.reset();
        }
        g_ready.store(false);
    });
}

void remember_bridge(JNIEnv* env, jobject bridge) {
    std::scoped_lock lock(g_bridge_mutex);
    if (g_bridge_class != nullptr) return;
    jclass local = env->GetObjectClass(bridge);
    g_bridge_class = reinterpret_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeInitialize(JNIEnv* env,
                                                                       jobject bridge) {
    remember_bridge(env, bridge);
    start_worker();
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeSdkVersion(JNIEnv* env, jobject) {
    const std::string version = std::to_string(discordpp::Client::GetVersionMajor()) + "." +
                                std::to_string(discordpp::Client::GetVersionMinor()) + "." +
                                std::to_string(discordpp::Client::GetVersionPatch());
    return env->NewStringUTF(version.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeAuthenticate(JNIEnv*,
                                                                        jobject,
                                                                        jboolean use_device_flow) {
    const auto auth_generation = g_auth_generation.fetch_add(1) + 1;
    post([use_device_flow, auth_generation] {
        if (auth_generation != g_auth_generation.load()) return;
        if (!g_client) {
            notify_auth("onAuthResult", false, {}, {}, 0, 0, {},
                        "Discord is not ready. Please try again.");
            return;
        }
        if (use_device_flow == JNI_TRUE) {
            discordpp::DeviceAuthorizationArgs args;
            args.SetClientId(kApplicationId);
            args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
            g_client->GetTokenFromDevice(
                std::move(args),
                [auth_generation](discordpp::ClientResult result,
                                  std::string access_token,
                                  std::string refresh_token,
                                  discordpp::AuthorizationTokenType token_type,
                                  std::int32_t expires_in,
                                  std::string scopes) {
                    if (auth_generation != g_auth_generation.load()) return;
                    notify_token_result("onAuthResult",
                                        std::move(result),
                                        std::move(access_token),
                                        std::move(refresh_token),
                                        token_type,
                                        expires_in,
                                        std::move(scopes));
                });
            return;
        }
        auto verifier = g_client->CreateAuthorizationCodeVerifier();
        const std::string verifier_value = verifier.Verifier();
        discordpp::AuthorizationArgs args;
        args.SetClientId(kApplicationId);
        args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
        args.SetCodeChallenge(verifier.Challenge());
        args.SetCustomSchemeParam("discord-" + std::to_string(kApplicationId));
        g_client->Authorize(
            std::move(args),
            [verifier_value, auth_generation](discordpp::ClientResult result,
                                              std::string code,
                                              std::string redirect_uri) {
                if (auth_generation != g_auth_generation.load()) return;
                if (!succeeded(result)) {
                    notify_auth("onAuthResult",
                                false,
                                {},
                                {},
                                0,
                                0,
                                {},
                                safe_error(result));
                    return;
                }
                if (!g_client || code.empty() || redirect_uri.empty()) {
                    notify_auth("onAuthResult",
                                false,
                                {},
                                {},
                                0,
                                0,
                                {},
                                "Discord did not return a usable authorization code.");
                    return;
                }
                g_client->GetToken(
                    kApplicationId,
                    code,
                    verifier_value,
                    redirect_uri,
                    [auth_generation](discordpp::ClientResult token_result,
                                      std::string access_token,
                                      std::string refresh_token,
                                      discordpp::AuthorizationTokenType token_type,
                                      std::int32_t expires_in,
                                      std::string scopes) {
                        if (auth_generation != g_auth_generation.load()) return;
                        notify_token_result("onAuthResult",
                                            std::move(token_result),
                                            std::move(access_token),
                                            std::move(refresh_token),
                                            token_type,
                                            expires_in,
                                            std::move(scopes));
                    });
            });
    });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeCancelAuthentication(
    JNIEnv*, jobject, jboolean use_device_flow) {
    g_auth_generation.fetch_add(1);
    post([use_device_flow] {
        if (!g_client) return;
        if (use_device_flow == JNI_TRUE) {
            g_client->AbortGetTokenFromDevice();
        } else {
            g_client->AbortAuthorize();
        }
    });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeRefreshToken(JNIEnv* env,
                                                                         jobject,
                                                                         jstring token) {
    const std::string refresh_token = from_jstring(env, token);
    post([refresh_token] {
        if (!g_client) return;
        g_client->RefreshToken(
            kApplicationId,
            refresh_token,
            [](discordpp::ClientResult result,
               std::string access_token,
               std::string new_refresh_token,
               discordpp::AuthorizationTokenType token_type,
               std::int32_t expires_in,
               std::string scopes) {
                const bool ok = succeeded(result);
                notify_auth("onRefreshResult",
                            ok,
                            ok ? access_token : std::string{},
                            ok ? new_refresh_token : std::string{},
                            static_cast<int>(token_type),
                            ok ? expires_in : 0,
                            ok ? scopes : std::string{},
                            ok ? std::string{} : safe_error(result));
            });
    });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeConnect(JNIEnv* env,
                                                                    jobject,
                                                                    jstring token,
                                                                    jint token_type) {
    const std::string access_token = from_jstring(env, token);
    const auto connection_generation = g_connection_generation.fetch_add(1) + 1;
    post([access_token, token_type, connection_generation] {
        if (!g_client || connection_generation != g_connection_generation.load()) return;
        g_connection_requested = true;
        const auto initial_status = g_client->GetStatus();
        g_manual_connect_after_token_update =
            initial_status == discordpp::Client::Status::Disconnected ||
            initial_status == discordpp::Client::Status::Disconnecting;
        g_token_ready_connection_generation = 0;
        g_client->UpdateToken(
            static_cast<discordpp::AuthorizationTokenType>(token_type),
            access_token,
            [connection_generation](discordpp::ClientResult result) {
                const bool ok = succeeded(result);
                std::string error = ok ? std::string{} : safe_error(result);
                post([connection_generation, ok, error = std::move(error)] {
                    if (!g_client ||
                        connection_generation != g_connection_generation.load()) {
                        return;
                    }
                    if (!ok) {
                        g_connection_requested = false;
                        g_manual_connect_after_token_update = false;
                        g_token_ready_connection_generation = 0;
                        notify_status("error", error);
                        return;
                    }
                    g_token_ready_connection_generation = connection_generation;
                    // UpdateToken may reconnect an already-connected client by
                    // itself. Calling Connect unconditionally here creates a
                    // second websocket transition. Manually connect only when
                    // this request began with a fully disconnected client.
                    if (connect_pending_if_disconnected()) return;
                    const auto status = g_client->GetStatus();
                    if (status == discordpp::Client::Status::Ready) {
                        g_connection_requested = false;
                        g_manual_connect_after_token_update = false;
                        g_token_ready_connection_generation = 0;
                        notify_status("ready");
                        flush_pending_presence();
                    }
                });
            });
    });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeRevoke(JNIEnv* env,
                                                                   jobject,
                                                                   jstring token) {
    const std::string value = from_jstring(env, token);
    post([value] {
        if (!g_client) return;
        g_client->RevokeToken(kApplicationId, value, [](discordpp::ClientResult result) {
            notify_simple("onRevokeResult", succeeded(result),
                          succeeded(result) ? std::string{} : safe_error(result));
        });
    });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeUpdatePlaybackPresence(
    JNIEnv* env,
    jobject,
    jstring title,
    jint episode,
    jboolean playing,
    jlong position_ms,
    jlong duration_ms,
    jstring artwork_url) {
    Presence presence{
        "watching",
        from_jstring(env, title),
        static_cast<int>(episode),
        "",
        0,
        0,
        playing == JNI_TRUE,
        static_cast<std::int64_t>(position_ms),
        static_cast<std::int64_t>(duration_ms),
        from_jstring(env, artwork_url),
    };
    post([presence = std::move(presence)] { publish_presence(presence); });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeUpdateReadingPresence(
    JNIEnv* env,
    jobject,
    jstring title,
    jstring chapter_label,
    jint page,
    jint page_count) {
    Presence presence{
        "reading",
        from_jstring(env, title),
        0,
        from_jstring(env, chapter_label),
        static_cast<int>(page),
        static_cast<int>(page_count),
        false,
        0,
        0,
        "",
    };
    post([presence = std::move(presence)] { publish_presence(presence); });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeClearPresence(JNIEnv*, jobject) {
    post([] {
        g_pending_presence.reset();
        g_last_submitted_presence.reset();
        if (!g_client || !g_ready.load()) return;
        if (g_presence_update_in_flight) {
            g_clear_presence_pending = true;
            return;
        }
        g_client->ClearRichPresence();
    });
}

extern "C" JNIEXPORT void JNICALL
Java_dev_animetv_anime_1tv_DiscordRichPresenceBridge_nativeDisconnect(JNIEnv*, jobject) {
    // Invalidate an UpdateToken callback before its queued worker command can
    // race this disconnect and open a replacement websocket afterward.
    g_connection_generation.fetch_add(1);
    post([] {
        g_pending_presence.reset();
        g_last_submitted_presence.reset();
        g_clear_presence_pending = false;
        const bool had_presence_update_in_flight = g_presence_update_in_flight;
        ++g_presence_operation_generation;
        g_presence_update_in_flight = false;
        g_connection_requested = false;
        g_manual_connect_after_token_update = false;
        g_token_ready_connection_generation = 0;
        g_ready.store(false);
        if (g_client) {
            // Do not overlap a synchronous clear with an asynchronous
            // UpdateRichPresence write. Disconnect itself tears down the
            // remote activity and the SDK's websocket.
            if (!had_presence_update_in_flight) g_client->ClearRichPresence();
            g_client->Disconnect();
        }
    });
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM*, void*) {
    g_running.store(false);
    g_command_cv.notify_all();
    if (g_worker.joinable()) g_worker.join();
    bool attached = false;
    JNIEnv* env = current_env(&attached);
    if (env != nullptr) {
        std::scoped_lock lock(g_bridge_mutex);
        if (g_bridge_class != nullptr) {
            env->DeleteGlobalRef(g_bridge_class);
            g_bridge_class = nullptr;
        }
    }
    if (attached) g_vm->DetachCurrentThread();
}
