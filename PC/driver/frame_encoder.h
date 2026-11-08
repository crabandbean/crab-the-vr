//
//  frame_encoder.h
//  JoyVR PC companion
//
//  Takes the shared backbuffer the SteamVR compositor hands the driver, turns
//  it into an H.264 Annex-B stream and pushes it to the phone in the datagrams
//  described by PC/PROTOCOL.md.
//

#pragma once

#include <windows.h>
#include <d3d11.h>

#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

struct SharedTextureFrame {
    HANDLE handle = nullptr;
    double vsyncSeconds = 0.0;
    uint64_t number = 0;
};

class FrameEncoder {
public:
    FrameEncoder();
    ~FrameEncoder();

    bool start(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrateKbps);
    void stop();

    /// Where the next frames go. Called whenever a pose packet arrives.
    void setTarget(const sockaddr_in &address);
    void clearTarget();

    /// Called on the compositor thread with the shareable backbuffer texture.
    void submit(SharedTextureFrame frame);

private:
    struct Encoder;
    void workerLoop();
    bool encodeTexture(ID3D11Texture2D *texture, std::vector<uint8_t> &annexB, bool &keyframe);
    void sendAccessUnit(const std::vector<uint8_t> &annexB, bool keyframe);

    std::thread m_worker;
    std::mutex m_frameLock;
    std::mutex m_targetLock;

    SharedTextureFrame m_pending;
    bool m_hasFrame = false;
    bool m_running = false;

    sockaddr_in m_target{};
    bool m_hasTarget = false;

    ID3D11Device *m_device = nullptr;
    ID3D11DeviceContext *m_context = nullptr;
    ID3D11Texture2D *m_staging = nullptr;

    Encoder *m_encoder = nullptr;
    uint32_t m_width = 0;
    uint32_t m_height = 0;
    uint64_t m_frameCounter = 0;
    uint64_t m_sampleTime = 0;
};
