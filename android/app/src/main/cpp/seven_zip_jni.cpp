#include <jni.h>
#include "libplzma.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
struct JavaFailure {};
struct Cancelled {};
struct PasswordFailure : std::runtime_error { using std::runtime_error::runtime_error; };

void checkJava(JNIEnv* env) { if (env->ExceptionCheck()) throw JavaFailure{}; }

// JNI's GetStringUTFChars is modified UTF-8, incompatible with archive passwords and emoji.
std::string utf8(JNIEnv* env, jstring value) {
    if (!value) return {};
    const jsize length = env->GetStringLength(value);
    const jchar* chars = env->GetStringChars(value, nullptr);
    checkJava(env);
    if (!chars) throw std::bad_alloc();
    struct Release { JNIEnv* e; jstring s; const jchar* p; ~Release() { e->ReleaseStringChars(s, p); } } release{env, value, chars};
    std::string result;
    result.reserve(length);
    for (jsize i = 0; i < length; ++i) {
        uint32_t c = chars[i];
        if (c >= 0xd800 && c <= 0xdbff) {
            if (++i >= length || chars[i] < 0xdc00 || chars[i] > 0xdfff) throw std::runtime_error("Invalid Unicode string.");
            c = 0x10000 + ((c - 0xd800) << 10) + (chars[i] - 0xdc00);
        } else if (c >= 0xdc00 && c <= 0xdfff) throw std::runtime_error("Invalid Unicode string.");
        if (!c) throw std::runtime_error("Embedded NUL is unsupported in archive paths or passwords.");
        if (c < 0x80) result.push_back(static_cast<char>(c));
        else if (c < 0x800) {
            result.push_back(static_cast<char>(0xc0 | (c >> 6)));
            result.push_back(static_cast<char>(0x80 | (c & 63)));
        } else if (c < 0x10000) {
            result.push_back(static_cast<char>(0xe0 | (c >> 12)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 63)));
            result.push_back(static_cast<char>(0x80 | (c & 63)));
        } else {
            result.push_back(static_cast<char>(0xf0 | (c >> 18)));
            result.push_back(static_cast<char>(0x80 | ((c >> 12) & 63)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 63)));
            result.push_back(static_cast<char>(0x80 | (c & 63)));
        }
    }
    return result;
}

jstring javaString(JNIEnv* env, const std::string& source) {
    std::vector<jchar> result;
    result.reserve(source.size());
    for (size_t i = 0; i < source.size();) {
        const auto lead = static_cast<uint8_t>(source[i++]);
        uint32_t c; size_t remaining; uint32_t minimum;
        if (lead < 0x80) { c = lead; remaining = 0; minimum = 0; }
        else if ((lead & 0xe0) == 0xc0) { c = lead & 31; remaining = 1; minimum = 0x80; }
        else if ((lead & 0xf0) == 0xe0) { c = lead & 15; remaining = 2; minimum = 0x800; }
        else if ((lead & 0xf8) == 0xf0) { c = lead & 7; remaining = 3; minimum = 0x10000; }
        else throw std::runtime_error("Invalid UTF-8 archive filename.");
        if (remaining > source.size() - i) throw std::runtime_error("Truncated UTF-8 archive filename.");
        while (remaining--) {
            const auto next = static_cast<uint8_t>(source[i++]);
            if ((next & 0xc0) != 0x80) throw std::runtime_error("Invalid UTF-8 archive filename.");
            c = (c << 6) | (next & 63);
        }
        if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff) || !c) throw std::runtime_error("Invalid Unicode archive filename.");
        if (c <= 0xffff) result.push_back(static_cast<jchar>(c));
        else { c -= 0x10000; result.push_back(static_cast<jchar>(0xd800 + (c >> 10))); result.push_back(static_cast<jchar>(0xdc00 + (c & 1023))); }
    }
    auto value = env->NewString(result.data(), static_cast<jsize>(result.size()));
    checkJava(env);
    return value;
}

struct Secret {
    std::string value;
    ~Secret() { volatile char* p = value.empty() ? nullptr : &value[0]; for (size_t i = 0; i < value.size(); ++i) p[i] = 0; }
};

// Only atomics run on SDK progress callbacks. A dedicated JNI-attached monitor polls cancellation
// and aborts outside the SDK callback mutex, including during encrypted header opening.
class Monitor final : public plzma::ProgressDelegate {
    JavaVM* vm_ = nullptr;
    JNIEnv* owner_;
    jobject callbacks_ = nullptr;
    jmethodID cancelledMethod_, progressMethod_;
    plzma::SharedPtr<plzma::Decoder> decoder_;
    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable wake_;
    bool done_ = false;
    jobject callbackError_ = nullptr;
    std::atomic<bool> cancelled_{false}, callbackFailed_{false};
    std::atomic<float> progress_{0};

    void run() noexcept {
        JNIEnv* env = nullptr;
#ifdef __ANDROID__
        const auto attached = vm_->AttachCurrentThread(&env, nullptr);
#else
        const auto attached = vm_->AttachCurrentThread(reinterpret_cast<void**>(&env), nullptr);
#endif
        if (attached != JNI_OK) { callbackFailed_ = true; try { decoder_->abort(); } catch (...) {} return; }
        auto captureError = [&]() {
            if (!env->ExceptionCheck()) return false;
            jthrowable error = env->ExceptionOccurred();
            env->ExceptionClear();
            callbackError_ = env->NewGlobalRef(error);
            env->DeleteLocalRef(error);
            if (env->ExceptionCheck()) env->ExceptionClear();
            callbackFailed_ = true;
            return true;
        };
        float last = -1;
        auto lastReport = std::chrono::steady_clock::now() - std::chrono::seconds(1);
        while (true) {
            { std::unique_lock<std::mutex> lock(mutex_); if (done_) break; }
            const bool cancelled = env->CallBooleanMethod(callbacks_, cancelledMethod_);
            if (captureError() || cancelled) {
                cancelled_ = cancelled;
                try { decoder_->abort(); } catch (...) {}
                break;
            }
            const float value = progress_.load();
            const auto now = std::chrono::steady_clock::now();
            if (value != last && now - lastReport >= std::chrono::milliseconds(100)) {
                env->CallVoidMethod(callbacks_, progressMethod_, value);
                if (captureError()) { try { decoder_->abort(); } catch (...) {} break; }
                last = value; lastReport = now;
            }
            std::unique_lock<std::mutex> lock(mutex_);
            if (wake_.wait_for(lock, std::chrono::milliseconds(30), [&] { return done_; })) break;
        }
        vm_->DetachCurrentThread();
    }
public:
    Monitor(JNIEnv* env, jobject callbacks, const plzma::SharedPtr<plzma::Decoder>& decoder)
        : owner_(env), decoder_(decoder) {
        if (env->GetJavaVM(&vm_) != JNI_OK) throw std::runtime_error("Cannot access Java VM.");
        auto cls = env->GetObjectClass(callbacks);
        cancelledMethod_ = env->GetMethodID(cls, "isCancelled", "()Z");
        progressMethod_ = env->GetMethodID(cls, "onProgress", "(F)V");
        env->DeleteLocalRef(cls);
        checkJava(env);
        callbacks_ = env->NewGlobalRef(callbacks);
        checkJava(env);
        try { thread_ = std::thread([this] { run(); }); }
        catch (...) { env->DeleteGlobalRef(callbacks_); throw; }
    }
    ~Monitor() {
        stop();
        if (callbackError_) owner_->DeleteGlobalRef(callbackError_);
        owner_->DeleteGlobalRef(callbacks_);
    }
    void stop() {
        { std::lock_guard<std::mutex> lock(mutex_); done_ = true; }
        wake_.notify_all();
        if (thread_.joinable()) thread_.join();
    }
    void check() {
        if (callbackFailed_) throw std::runtime_error("Archive callback failed.");
        if (cancelled_) throw Cancelled{};
    }
    void finish() {
        stop();
        if (callbackError_ && !owner_->ExceptionCheck()) { owner_->Throw(static_cast<jthrowable>(callbackError_)); throw JavaFailure{}; }
        check();
    }
    void onProgress(void*, const plzma::String&, double value) override {
        if (std::isfinite(value)) progress_ = static_cast<float>(std::clamp(value, 0.0, 1.0));
    }
};

void throwJava(JNIEnv* env, const char* klass, const char* message) {
    if (env->ExceptionCheck()) return;
    auto cls = env->FindClass(klass);
    if (cls) { env->ThrowNew(cls, message); env->DeleteLocalRef(cls); }
}
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_brite_zipimageviewer_nativebridge_NativeSevenZip_extractNative(
    JNIEnv* env, jobject, jstring archivePath, jstring password, jobject callbacks) {
    bool opened = false, encryptedSelection = false;
    try {
        const std::string archive = utf8(env, archivePath);
        std::ifstream file(archive, std::ios::binary);
        if (!file) throw std::runtime_error("Cannot read archive file.");
        const unsigned char expected[] = {0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c};
        unsigned char signature[6] = {};
        file.read(reinterpret_cast<char*>(signature), sizeof(signature));
        if (file.gcount() != 6 || !std::equal(std::begin(signature), std::end(signature), std::begin(expected)))
            throw std::runtime_error("This file is not a valid 7z archive.");
        file.close();
        auto input = plzma::makeSharedInStream(plzma::Path(archive.c_str()));
        auto decoder = plzma::makeSharedDecoder(input, plzma_file_type_7z);
        Secret secret{utf8(env, password)};
        decoder->setPassword(password ? secret.value.c_str() : static_cast<const char*>(nullptr));
        auto cls = env->GetObjectClass(callbacks);
        const auto reserveMethod = env->GetMethodID(cls, "reserve", "(Ljava/lang/String;J)Ljava/lang/String;");
        const auto prepareMethod = env->GetMethodID(cls, "prepare", "()V");
        const auto timesMethod = env->GetMethodID(cls, "recordTimes", "(Ljava/lang/String;JJ)V");
        const auto cancelMethod = env->GetMethodID(cls, "isCancelled", "()Z");
        const auto progressMethod = env->GetMethodID(cls, "onProgress", "(F)V");
        env->DeleteLocalRef(cls);
        checkJava(env);
        auto cancellationCheck = [&] {
            checkJava(env);
            const bool cancelled = env->CallBooleanMethod(callbacks, cancelMethod);
            checkJava(env);
            if (cancelled) throw Cancelled{};
        };
        cancellationCheck();
        Monitor monitor(env, callbacks, decoder);
        decoder->setProgressDelegate(&monitor);
        struct ClearDelegate { plzma::SharedPtr<plzma::Decoder> d; ~ClearDelegate() { try { d->setProgressDelegate(nullptr); } catch (...) {} } } clearDelegate{decoder};
        std::vector<std::string> names;
        try {
            opened = decoder->open();
            monitor.check();
            cancellationCheck();
            if (!opened) throw PasswordFailure("Cannot open 7z archive. A password may be required, or the archive is damaged or unsupported.");
            const auto count = decoder->count();
            if (count > 100000) throw std::runtime_error("Archive exceeds the 100,000 entry limit.");
            struct Entry { plzma::SharedPtr<plzma::Item> item; std::string path; };
            std::vector<Entry> selected;
            for (plzma_size_t i = 0; i < count; ++i) {
                monitor.check(); cancellationCheck();
                auto item = decoder->itemAt(i);
                if (item->isDir()) continue;
                const std::string name = item->path().utf8();
                auto jname = javaString(env, name);
                auto destination = static_cast<jstring>(env->CallObjectMethod(callbacks, reserveMethod, jname, static_cast<jlong>(item->size())));
                checkJava(env);
                if (!destination) { env->DeleteLocalRef(jname); continue; }
                // Archive metadata, not the extraction filesystem's creation/modification time.
                const auto milliseconds = [](time_t seconds) -> jlong {
                    if (seconds > std::numeric_limits<jlong>::max() / 1000 ||
                        seconds < std::numeric_limits<jlong>::min() / 1000) return 0;
                    return static_cast<jlong>(seconds) * 1000;
                };
                env->CallVoidMethod(callbacks, timesMethod, jname,
                                    milliseconds(item->modificationTime()), milliseconds(item->creationTime()));
                env->DeleteLocalRef(jname);
                checkJava(env);
                const std::string path = utf8(env, destination);
                env->DeleteLocalRef(destination);
                selected.push_back({item, path});
                names.push_back(name);
                encryptedSelection = encryptedSelection || item->encrypted();
            }
            if (selected.empty()) throw std::runtime_error("Archive contains no supported JPG, JPEG or PNG images.");
            if (encryptedSelection && !password) throw PasswordFailure("A password is required to extract this archive.");
            env->CallVoidMethod(callbacks, prepareMethod);
            checkJava(env);
            auto streams = plzma::makeShared<plzma::ItemOutStreamArray>(static_cast<plzma_size_t>(selected.size()));
            for (const auto& entry : selected) {
                monitor.check(); cancellationCheck();
                streams->push(plzma::Pair<plzma::SharedPtr<plzma::Item>, plzma::SharedPtr<plzma::OutStream>>(
                    entry.item, plzma::makeSharedOutStream(plzma::Path(entry.path.c_str()))));
            }
            const bool extracted = decoder->extract(streams);
            monitor.check(); cancellationCheck();
            if (!extracted) {
                if (encryptedSelection) throw PasswordFailure("The password is incorrect, or the encrypted archive is damaged or unsupported.");
                throw std::runtime_error("The archive is damaged or uses an unsupported compression method.");
            }
            monitor.finish();
        } catch (...) {
            // Join before examining cancellation/callback failures or destroying streams/delegate.
            monitor.finish();
            cancellationCheck();
            throw;
        }
        auto stringClass = env->FindClass("java/lang/String");
        checkJava(env);
        auto result = env->NewObjectArray(static_cast<jsize>(names.size()), stringClass, nullptr);
        env->DeleteLocalRef(stringClass);
        checkJava(env);
        for (size_t i = 0; i < names.size(); ++i) {
            auto value = javaString(env, names[i]);
            env->SetObjectArrayElement(result, static_cast<jsize>(i), value);
            env->DeleteLocalRef(value);
            checkJava(env);
        }
        env->CallVoidMethod(callbacks, progressMethod, 1.0f);
        checkJava(env);
        return result;
    } catch (const JavaFailure&) {
        // Java exception from path validation, cancellation, callback, or allocation is already pending.
    } catch (const Cancelled&) {
        throwJava(env, "java/io/InterruptedIOException", "Archive import cancelled.");
    } catch (const PasswordFailure& error) {
        throwJava(env, "com/brite/zipimageviewer/nativebridge/PasswordRequiredException", error.what());
    } catch (const plzma::Exception& error) {
        if (error.code() == plzma_error_code_not_enough_memory)
            throwJava(env, "java/io/IOException", "The archive decoder requires more memory than is available.");
        else if (error.code() == plzma_error_code_io)
            throwJava(env, "java/io/IOException", "Cannot read archive or write extracted images.");
        else if (!opened || encryptedSelection)
            throwJava(env, "com/brite/zipimageviewer/nativebridge/PasswordRequiredException", "The password is required or incorrect, or the archive is damaged or unsupported.");
        else throwJava(env, "java/io/IOException", "The archive is damaged or uses an unsupported compression method.");
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/io/IOException", "Not enough memory to extract this archive.");
    } catch (const std::exception& error) {
        throwJava(env, "java/io/IOException", error.what());
    } catch (...) {
        throwJava(env, "java/io/IOException", "Unexpected native archive extraction failure.");
    }
    return nullptr;
}
