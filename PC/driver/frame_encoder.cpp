//
//  frame_encoder.cpp
//  JoyVR PC companion
//

#include "frame_encoder.h"

#include <d3d11.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <wrl/client.h>

#include <chrono>
#include <cstring>
#include <vector>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "ws2_32.lib")

using Microsoft::WRL::ComPtr;

namespace {

constexpr uint16_t kProtocolVersion = 1;
constexpr size_t kMaxPayload = 1200;
constexpr uint32_t kMagicVideo = 0x3156564A; // "JVV1" little endian

SOCKET g_videoSocket = INVALID_SOCKET;

bool ensureSocket() {
    if (g_videoSocket != INVALID_SOCKET) return true;
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) return false;
    int buffer = 4 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char *>(&buffer), sizeof(buffer));
    g_videoSocket = sock;
    return true;
}

void appendU16(std::vector<uint8_t> &out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
}

void appendU32(std::vector<uint8_t> &out, uint32_t value) {
    for (int index = 0; index < 4; ++index) {
        out.push_back(static_cast<uint8_t>((value >> (8 * index)) & 0xFF));
    }
}

void appendU64(std::vector<uint8_t> &out, uint64_t value) {
    for (int index = 0; index < 8; ++index) {
        out.push_back(static_cast<uint8_t>((value >> (8 * index)) & 0xFF));
    }
}

/// Rewrites AVCC (four byte length prefixed) NAL units as Annex-B.
std::vector<uint8_t> avccToAnnexB(const uint8_t *data, size_t size) {
    std::vector<uint8_t> out;
    size_t offset = 0;
    while (offset + 4 <= size) {
        uint32_t length = (uint32_t(data[offset]) << 24) | (uint32_t(data[offset + 1]) << 16) |
                          (uint32_t(data[offset + 2]) << 8) | uint32_t(data[offset + 3]);
        offset += 4;
        if (length == 0 || offset + length > size) break;
        out.push_back(0);
        out.push_back(0);
        out.push_back(0);
        out.push_back(1);
        out.insert(out.end(), data + offset, data + offset + length);
        offset += length;
    }
    if (out.empty()) {
        out.push_back(0);
        out.push_back(0);
        out.push_back(0);
        out.push_back(1);
        out.insert(out.end(), data, data + size);
    }
    return out;
}

} // namespace

struct FrameEncoder::Encoder {
    ComPtr<IMFTransform> transform;
    bool providesSamples = true;
};

FrameEncoder::FrameEncoder() = default;

FrameEncoder::~FrameEncoder() {
    stop();
    if (m_staging) m_staging->Release();
    if (m_context) m_context->Release();
    if (m_device) m_device->Release();
}

bool FrameEncoder::start(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrateKbps) {
    if (m_running) return true;
    if (width == 0 || height == 0 || fps == 0) return false;

    m_width = width;
    m_height = height;

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(MFStartup(MF_VERSION))) return false;

    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels,
                                   ARRAYSIZE(levels), D3D11_SDK_VERSION, &m_device, nullptr, &m_context);
    if (FAILED(hr)) {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels, ARRAYSIZE(levels),
                               D3D11_SDK_VERSION, &m_device, nullptr, &m_context);
        if (FAILED(hr)) return false;
    }

    D3D11_TEXTURE2D_DESC staging{};
    staging.Width = width;
    staging.Height = height;
    staging.MipLevels = 1;
    staging.ArraySize = 1;
    staging.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    staging.SampleDesc.Count = 1;
    staging.Usage = D3D11_USAGE_STAGING;
    staging.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(m_device->CreateTexture2D(&staging, nullptr, &m_staging))) return false;

    m_encoder = new Encoder();
    hr = CoCreateInstance(CLSID_CMSH264EncoderMFT, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&m_encoder->transform));
    if (FAILED(hr)) {
        delete m_encoder;
        m_encoder = nullptr;
        return false;
    }

    ComPtr<IMFMediaType> outputType;
    if (FAILED(MFCreateMediaType(&outputType))) return false;
    outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    outputType->SetUINT32(MF_MT_AVG_BITRATE, bitrateKbps * 1000);
    outputType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(outputType.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(outputType.Get(), MF_MT_FRAME_RATE, fps, 1);
    MFSetAttributeRatio(outputType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    // The H.264 encoder wants its output type set before the input type.
    if (FAILED(m_encoder->transform->SetOutputType(0, outputType.Get(), 0))) return false;

    ComPtr<IMFMediaType> inputType;
    if (FAILED(MFCreateMediaType(&inputType))) return false;
    inputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    inputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    inputType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(inputType.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(inputType.Get(), MF_MT_FRAME_RATE, fps, 1);
    MFSetAttributeRatio(inputType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (FAILED(m_encoder->transform->SetInputType(0, inputType.Get(), 0))) return false;

    MFT_OUTPUT_STREAM_INFO info{};
    if (SUCCEEDED(m_encoder->transform->GetOutputStreamInfo(0, &info))) {
        m_encoder->providesSamples = (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
    }

    ComPtr<ICodecAPI> codecApi;
    if (SUCCEEDED(m_encoder->transform->QueryInterface(IID_PPV_ARGS(&codecApi)))) {
        VARIANT value;
        VariantInit(&value);
        value.vt = VT_UI4;
        value.ulVal = fps;
        codecApi->SetValue(&CODECAPI_AVEncMPVGOPSize, &value);
        codecApi.Reset();
    }

    m_encoder->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    m_encoder->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    ensureSocket();

    m_running = true;
    m_worker = std::thread(&FrameEncoder::workerLoop, this);
    return true;
}

void FrameEncoder::stop() {
    if (m_running) {
        m_running = false;
        if (m_worker.joinable()) m_worker.join();
    }
    if (m_encoder) {
        if (m_encoder->transform) {
            m_encoder->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        }
        delete m_encoder;
        m_encoder = nullptr;
    }
}

void FrameEncoder::setTarget(const sockaddr_in &address) {
    std::lock_guard<std::mutex> guard(m_targetLock);
    m_target = address;
    m_hasTarget = true;
}

void FrameEncoder::clearTarget() {
    std::lock_guard<std::mutex> guard(m_targetLock);
    m_hasTarget = false;
}

void FrameEncoder::submit(SharedTextureFrame frame) {
    std::lock_guard<std::mutex> guard(m_frameLock);
    if (m_hasFrame && m_pending.handle) {
        CloseHandle(m_pending.handle);
    }
    m_pending = frame;
    m_hasFrame = true;
}

void FrameEncoder::workerLoop() {
    while (m_running) {
        SharedTextureFrame frame;
        bool hasFrame = false;
        {
            std::lock_guard<std::mutex> guard(m_frameLock);
            if (m_hasFrame) {
                frame = m_pending;
                m_pending.handle = nullptr;
                m_hasFrame = false;
                hasFrame = true;
            }
        }

        if (!hasFrame) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }

        if (!m_device) {
            if (frame.handle) CloseHandle(frame.handle);
            continue;
        }

        ID3D11Texture2D *texture = nullptr;
        HRESULT hr = m_device->OpenSharedResource(frame.handle, __uuidof(ID3D11Texture2D),
                                                  reinterpret_cast<void **>(&texture));
        if (frame.handle) CloseHandle(frame.handle);
        if (FAILED(hr) || !texture) {
            continue;
        }

        std::vector<uint8_t> annexB;
        bool keyframe = false;
        if (encodeTexture(texture, annexB, keyframe)) {
            sendAccessUnit(annexB, keyframe);
        }
        texture->Release();
    }
}

bool FrameEncoder::encodeTexture(ID3D11Texture2D *texture, std::vector<uint8_t> &annexB, bool &keyframe) {
    if (!m_context || !m_staging || !m_encoder || !m_encoder->transform) return false;

    m_context->CopyResource(m_staging, texture);

    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(m_context->Map(m_staging, 0, D3D11_MAP_READ, 0, &mapped))) return false;

    const uint32_t rowPitch = mapped.RowPitch;
    const uint32_t width = m_width;
    const uint32_t height = m_height;
    const auto *source = static_cast<const uint8_t *>(mapped.pData);

    const size_t ySize = size_t(width) * height;
    std::vector<uint8_t> nv12(ySize + ySize / 2);
    uint8_t *yPlane = nv12.data();
    uint8_t *uvPlane = nv12.data() + ySize;

    // BGRA to NV12, BT.601 limited range.
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t *row = source + size_t(y) * rowPitch;
        for (uint32_t x = 0; x < width; ++x) {
            const uint8_t b = row[x * 4 + 0];
            const uint8_t g = row[x * 4 + 1];
            const uint8_t r = row[x * 4 + 2];
            const int luma = (66 * r + 129 * g + 25 * b + 128) >> 8;
            yPlane[size_t(y) * width + x] =
                static_cast<uint8_t>(luma < 0 ? 0 : (luma > 255 ? 255 : luma));
        }
        if ((y & 1) == 0) {
            uint8_t *uvRow = uvPlane + size_t(y / 2) * width;
            for (uint32_t x = 0; x + 1 < width; x += 2) {
                const int r = (row[x * 4 + 2] + row[(x + 1) * 4 + 2]) / 2;
                const int g = (row[x * 4 + 1] + row[(x + 1) * 4 + 1]) / 2;
                const int b = (row[x * 4 + 0] + row[(x + 1) * 4 + 0]) / 2;
                const int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                const int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                uvRow[x] = static_cast<uint8_t>(u < 0 ? 0 : (u > 255 ? 255 : u));
                uvRow[x + 1] = static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
            }
        }
    }

    m_context->Unmap(m_staging, 0);

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(nv12.size()), &buffer))) return false;

    BYTE *destination = nullptr;
    if (FAILED(buffer->Lock(&destination, nullptr, nullptr))) return false;
    std::memcpy(destination, nv12.data(), nv12.size());
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(nv12.size()));

    ComPtr<IMFSample> sample;
    if (FAILED(MFCreateSample(&sample))) return false;
    sample->AddBuffer(buffer.Get());

    const LONGLONG duration = 10'000'000LL / 90;
    sample->SetSampleTime(static_cast<LONGLONG>(m_sampleTime));
    sample->SetSampleDuration(duration);
    m_sampleTime += duration;

    if (FAILED(m_encoder->transform->ProcessInput(0, sample.Get(), 0))) return false;

    annexB.clear();

    MFT_OUTPUT_DATA_BUFFER output{};
    DWORD status = 0;
    while (true) {
        ComPtr<IMFSample> providedSample;
        if (m_encoder->providesSamples) {
            output.pSample = nullptr;
        } else {
            ComPtr<IMFMediaBuffer> outBuffer;
            if (FAILED(MFCreateMemoryBuffer(width * height * 3, &outBuffer))) break;
            if (FAILED(MFCreateSample(&providedSample))) break;
            providedSample->AddBuffer(outBuffer.Get());
            output.pSample = providedSample.Get();
        }
        output.dwStreamID = 0;
        output.dwStatus = 0;
        output.pEvents = nullptr;

        const HRESULT hr = m_encoder->transform->ProcessOutput(0, 1, &output, &status);
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) break;
        if (FAILED(hr)) break;

        IMFSample *sampleOut = output.pSample;
        if (sampleOut) {
            IMFMediaBuffer *mediaBuffer = nullptr;
            if (SUCCEEDED(sampleOut->ConvertToContiguousBuffer(&mediaBuffer)) && mediaBuffer) {
                BYTE *data = nullptr;
                DWORD length = 0;
                if (SUCCEEDED(mediaBuffer->Lock(&data, nullptr, &length))) {
                    std::vector<uint8_t> converted = avccToAnnexB(data, length);
                    annexB.insert(annexB.end(), converted.begin(), converted.end());
                    mediaBuffer->Unlock();
                }
                mediaBuffer->Release();
            }
            if (m_encoder->providesSamples) {
                sampleOut->Release();
            }
        }
        if (output.pEvents) output.pEvents->Release();
    }

    // An IDR slice (NAL type 5) in the stream marks a frame the phone can start from.
    keyframe = false;
    for (size_t index = 0; index + 4 < annexB.size(); ++index) {
        if (annexB[index] == 0 && annexB[index + 1] == 0 && annexB[index + 2] == 1 &&
            (annexB[index + 3] & 0x1F) == 5) {
            keyframe = true;
            break;
        }
    }

    return !annexB.empty();
}

void FrameEncoder::sendAccessUnit(const std::vector<uint8_t> &annexB, bool keyframe) {
    sockaddr_in target{};
    {
        std::lock_guard<std::mutex> guard(m_targetLock);
        if (!m_hasTarget) return;
        target = m_target;
    }

    if (!ensureSocket()) return;

    const size_t total = annexB.size();
    const size_t fragmentCount = (total + kMaxPayload - 1) / kMaxPayload;
    if (fragmentCount == 0) return;

    const uint64_t frameID = ++m_frameCounter;

    for (size_t index = 0; index < fragmentCount; ++index) {
        const size_t offset = index * kMaxPayload;
        const size_t length = (offset + kMaxPayload <= total) ? kMaxPayload : (total - offset);

        std::vector<uint8_t> packet;
        packet.reserve(24 + length);
        appendU32(packet, kMagicVideo);
        appendU16(packet, kProtocolVersion);
        appendU16(packet, keyframe ? 1 : 0);
        appendU64(packet, frameID);
        appendU16(packet, static_cast<uint16_t>(index));
        appendU16(packet, static_cast<uint16_t>(fragmentCount));
        appendU32(packet, static_cast<uint32_t>(total));
        packet.insert(packet.end(), annexB.begin() + offset, annexB.begin() + offset + length);

        sendto(g_videoSocket, reinterpret_cast<const char *>(packet.data()),
               static_cast<int>(packet.size()), 0,
               reinterpret_cast<const sockaddr *>(&target), sizeof(target));
    }
}
