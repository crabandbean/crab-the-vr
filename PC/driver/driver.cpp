//
//  driver.cpp
//  JoyVR PC companion — an OpenVR driver that presents the iPhone as a
//  wireless HMD.
//
//  It does three things:
//    * answers the phone's discovery broadcasts on UDP 8931
//    * receives head poses from the phone on UDP 8930 and feeds them to SteamVR
//    * hands every compositor frame to FrameEncoder, which streams it back
//
//  The wire format is documented in PC/PROTOCOL.md.
//

#include "openvr_driver.h"
#include "frame_encoder.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#pragma comment(lib, "openvr_api.lib")
#pragma comment(lib, "ws2_32.lib")

namespace {

constexpr uint16_t kProtocolVersion = 1;
constexpr uint16_t kStreamPort = 8930;
constexpr uint16_t kDiscoveryPort = 8931;

constexpr uint32_t kMagicPose = 0x3152564A;          // "JVR1"
constexpr uint32_t kMagicReply = 0x5052564A;         // "JVRP"
constexpr uint32_t kMagicDiscover = 0x5152564A;      // "JVRQ"
constexpr uint32_t kMagicDiscoverReply = 0x4552564A; // "JVRE"

constexpr uint16_t kPacketPose = 1;
constexpr uint16_t kPacketHello = 2;
constexpr uint16_t kPacketBye = 3;
constexpr uint16_t kPacketPing = 4;
constexpr uint16_t kPacketBitrate = 5;
constexpr uint16_t kPacketProfile = 6;
constexpr uint16_t kReplyAck = 1;
constexpr uint16_t kReplyPong = 3;

constexpr uint32_t kDefaultEyeWidth = 1280;
constexpr uint32_t kDefaultEyeHeight = 1280;
constexpr uint32_t kDefaultFPS = 90;
constexpr uint32_t kDefaultBitrateKbps = 60000;

/// The phone sends its pose as an offset from where the user last recentered,
/// so the driver adds a standing eye height to put the head where a person's is.
constexpr double kHeadHeightMetres = 1.6;

/// What the phone asked for in its hello. The encoder sizes itself from this.
struct StreamRequest {
    std::mutex lock;
    uint16_t width = kDefaultEyeWidth * 2;
    uint16_t height = kDefaultEyeHeight;
    uint16_t fps = static_cast<uint16_t>(kDefaultFPS);
    uint16_t bitrateKbps = static_cast<uint16_t>(kDefaultBitrateKbps);
};

struct HeadState {
    std::mutex lock;
    bool valid = false;
    double orientation[4] = {0.0, 0.0, 0.0, 1.0}; // x, y, z, w
    double position[3] = {0.0, 0.0, 0.0};
    double angularVelocity[3] = {0.0, 0.0, 0.0};
    float ipd = 0.064f;
    sockaddr_in phoneAddress{};
    bool havePhone = false;
    uint64_t lastPacketMs = 0;
};

StreamRequest g_request;
HeadState g_head;

// One record per controller in every pose packet. Twenty bytes each, laid out
// in PROTOCOL.md; the phone only sends pads whose role is not Ignore. Slots 4
// and 5 are the camera-tracked hands.
constexpr size_t kControllerRecordSize = 20;
constexpr size_t kHandRecordSize = 192;
constexpr uint64_t kControllerTimeoutMs = 2000;
constexpr uint64_t kHandTimeoutMs = 500;
constexpr int kMaxControllerSlots = 6;

struct ControllerState {
    std::mutex lock;
    bool present[kMaxControllerSlots] = {};
    // 0 left, 1 right, 2 gamepad.
    uint8_t role[kMaxControllerSlots] = {2, 2, 2, 2, 0, 1};
    uint16_t buttons[kMaxControllerSlots] = {};
    float leftStick[kMaxControllerSlots][2] = {};
    float rightStick[kMaxControllerSlots][2] = {};
    float leftTrigger[kMaxControllerSlots] = {};
    float rightTrigger[kMaxControllerSlots] = {};
    uint8_t battery[kMaxControllerSlots] = {255, 255, 255, 255, 255, 255};
    uint64_t lastPacketMs[kMaxControllerSlots] = {};

    // Hands only, in the head's own frame (metres, x y z quaternion).
    float handGrip[kMaxControllerSlots][3] = {};
    float handAimRotation[kMaxControllerSlots][4] = {};
};

ControllerState g_controllers;

/// The lens and comfort setup the phone last sent.
struct ProfileState {
    std::mutex lock;
    bool valid = false;
    uint16_t screenWidth = 2560;
    uint16_t screenHeight = 1280;
    float distortionK1 = 0.20f;
    float distortionK2 = 0.04f;
    float ipd = 0.064f;
    float supersampling = 1.0f;
    uint16_t refreshRate = 90;
    float fovCrop = 0.0f;
    float vignette = 0.0f;
    uint64_t lastPacketMs = 0;
};

ProfileState g_profile;

/// The head pose a hand is placed relative to.
struct HeadPose {
    bool valid = false;
    double orientation[4] = {0.0, 0.0, 0.0, 1.0}; // x, y, z, w
    double position[3] = {0.0, 0.0, 0.0};
};

FrameEncoder g_encoder;
std::atomic<bool> g_encoderRestart{false};

uint64_t nowMillis() {
    using namespace std::chrono;
    return static_cast<uint64_t>(
        duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

uint16_t readU16(const uint8_t *data) {
    return static_cast<uint16_t>(data[0]) | (static_cast<uint16_t>(data[1]) << 8);
}

uint32_t readU32(const uint8_t *data) {
    return static_cast<uint32_t>(data[0]) | (static_cast<uint32_t>(data[1]) << 8) |
           (static_cast<uint32_t>(data[2]) << 16) | (static_cast<uint32_t>(data[3]) << 24);
}

uint64_t readU64(const uint8_t *data) {
    uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value |= static_cast<uint64_t>(data[index]) << (8 * index);
    }
    return value;
}

float readF32(const uint8_t *data) {
    const uint32_t bits = readU32(data);
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

/// Rotates v by the quaternion q (x, y, z, w) into out.
void rotateVector(const double q[4], const double v[3], double out[3]) {
    const double x = q[0];
    const double y = q[1];
    const double z = q[2];
    const double w = q[3];

    const double tx = 2.0 * (y * v[2] - z * v[1]);
    const double ty = 2.0 * (z * v[0] - x * v[2]);
    const double tz = 2.0 * (x * v[1] - y * v[0]);

    out[0] = v[0] + w * tx + (y * tz - z * ty);
    out[1] = v[1] + w * ty + (z * tx - x * tz);
    out[2] = v[2] + w * tz + (x * ty - y * tx);
}

void multiplyQuaternions(const double a[4], const double b[4], double out[4]) {
    out[0] = a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1];
    out[1] = a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0];
    out[2] = a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3];
    out[3] = a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2];
}

/// Reads the controller records that follow the 72 byte pose. An old phone
/// sends no controllers at all, which is why a short packet is not an error.
void applyControllerRecords(const uint8_t *data, size_t size) {
    const uint8_t count = data[21];
    if (count == 0) return;
    if (size < 72 + static_cast<size_t>(count) * kControllerRecordSize) return;

    std::lock_guard<std::mutex> guard(g_controllers.lock);
    for (uint8_t index = 0; index < count && index < 4; ++index) {
        const uint8_t *record = data + 72 + static_cast<size_t>(index) * kControllerRecordSize;
        const uint8_t slot = record[0];
        if (slot >= 4) continue;

        g_controllers.role[slot] = record[1];
        g_controllers.buttons[slot] = readU16(record + 2);
        g_controllers.leftStick[slot][0] = static_cast<int16_t>(readU16(record + 4)) / 32767.0f;
        g_controllers.leftStick[slot][1] = static_cast<int16_t>(readU16(record + 6)) / 32767.0f;
        g_controllers.rightStick[slot][0] = static_cast<int16_t>(readU16(record + 8)) / 32767.0f;
        g_controllers.rightStick[slot][1] = static_cast<int16_t>(readU16(record + 10)) / 32767.0f;
        g_controllers.leftTrigger[slot] = record[12] / 255.0f;
        g_controllers.rightTrigger[slot] = record[13] / 255.0f;
        g_controllers.battery[slot] = record[14];
        g_controllers.lastPacketMs[slot] = nowMillis();
        g_controllers.present[slot] = true;
    }
}

/// Reads the hand records that follow the controller records. Each hand fills
/// slot 4 (left) or 5 (right) so the rest of the driver treats them like any
/// other tracked controller, with the hand's own grip and aim poses.
void applyHandRecords(const uint8_t *data, size_t size) {
    const uint8_t handCount = data[22];
    if (handCount == 0) return;

    const size_t offset = 72 + static_cast<size_t>(data[21]) * kControllerRecordSize;
    if (size < offset + static_cast<size_t>(handCount) * kHandRecordSize) return;

    std::lock_guard<std::mutex> guard(g_controllers.lock);
    for (uint8_t index = 0; index < handCount && index < 2; ++index) {
        const uint8_t *record = data + offset + static_cast<size_t>(index) * kHandRecordSize;
        const uint8_t hand = record[0];
        if (hand > 1) continue;

        const uint8_t slot = static_cast<uint8_t>(4 + hand);
        if ((record[1] & 1) == 0) {
            g_controllers.present[slot] = false;
            continue;
        }

        // 21 joints in millimetres: wrist, thumb CMC/MP/IP/tip, then four
        // joints each for index, middle, ring and little finger.
        auto joint = [&record](int index, int axis) -> float {
            const size_t offset = 64 + static_cast<size_t>(index) * 6 + static_cast<size_t>(axis) * 2;
            const int16_t value = static_cast<int16_t>(static_cast<uint16_t>(record[offset]) |
                                                       (static_cast<uint16_t>(record[offset + 1]) << 8));
            return value / 1000.0f;
        };
        auto distance = [&joint](int a, int b) -> float {
            const float dx = joint(a, 0) - joint(b, 0);
            const float dy = joint(a, 1) - joint(b, 1);
            const float dz = joint(a, 2) - joint(b, 2);
            return std::sqrt(dx * dx + dy * dy + dz * dz);
        };

        const float wristToMiddle = distance(0, 9);
        const float thumbToIndex = distance(4, 8);

        float pinch = readU16(record + 4) / 65535.0f;
        if (wristToMiddle > 0.02f) {
            pinch = 1.0f - thumbToIndex / (wristToMiddle * 0.9f);
            pinch = std::max(0.0f, std::min(1.0f, pinch));
        }

        g_controllers.role[slot] = hand;
        g_controllers.buttons[slot] = 0;
        g_controllers.leftStick[slot][0] = 0.0f;
        g_controllers.leftStick[slot][1] = 0.0f;
        g_controllers.rightStick[slot][0] = 0.0f;
        g_controllers.rightStick[slot][1] = 0.0f;
        g_controllers.leftTrigger[slot] = pinch;
        g_controllers.rightTrigger[slot] = pinch;
        g_controllers.battery[slot] = 255;

        g_controllers.handGrip[slot][0] = readF32(record + 8);
        g_controllers.handGrip[slot][1] = readF32(record + 12);
        g_controllers.handGrip[slot][2] = readF32(record + 16);
        for (int axis = 0; axis < 4; ++axis) {
            g_controllers.handAimRotation[slot][axis] = readF32(record + 48 + axis * 4);
        }

        g_controllers.lastPacketMs[slot] = nowMillis();
        g_controllers.present[slot] = true;
    }
}

void appendU16(std::string &out, uint16_t value) {
    out.push_back(static_cast<char>(value & 0xFF));
    out.push_back(static_cast<char>((value >> 8) & 0xFF));
}

void appendU32(std::string &out, uint32_t value) {
    for (int index = 0; index < 4; ++index) {
        out.push_back(static_cast<char>((value >> (8 * index)) & 0xFF));
    }
}

void appendU64(std::string &out, uint64_t value) {
    for (int index = 0; index < 8; ++index) {
        out.push_back(static_cast<char>((value >> (8 * index)) & 0xFF));
    }
}

std::string computerName() {
    char buffer[256] = {};
    DWORD size = sizeof(buffer);
    if (GetComputerNameA(buffer, &size) && size > 0) {
        return std::string(buffer, size);
    }
    return "Crab the VR PC";
}

// ---------------------------------------------------------------------------
// Networking: discovery, hello replies and pose reception
// ---------------------------------------------------------------------------

class PoseServer {
public:
    bool start() {
        WSADATA wsa{};
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;

        m_stream = openSocket(kStreamPort);
        m_discovery = openSocket(kDiscoveryPort);
        if (m_stream == INVALID_SOCKET || m_discovery == INVALID_SOCKET) return false;

        m_running = true;
        m_thread = std::thread(&PoseServer::loop, this);
        return true;
    }

    void stop() {
        m_running = false;
        if (m_thread.joinable()) m_thread.join();
        if (m_stream != INVALID_SOCKET) closesocket(m_stream);
        if (m_discovery != INVALID_SOCKET) closesocket(m_discovery);
        m_stream = m_discovery = INVALID_SOCKET;
        WSACleanup();
    }

private:
    static SOCKET openSocket(uint16_t port) {
        SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock == INVALID_SOCKET) return INVALID_SOCKET;

        BOOL reuse = TRUE;
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char *>(&reuse), sizeof(reuse));

        int buffer = 4 * 1024 * 1024;
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char *>(&buffer), sizeof(buffer));

        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_port = htons(port);
        if (bind(sock, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
            closesocket(sock);
            return INVALID_SOCKET;
        }
        u_long nonBlocking = 1;
        ioctlsocket(sock, FIONBIO, &nonBlocking);
        return sock;
    }

    void loop() {
        uint8_t buffer[2048];
        while (m_running) {
            bool worked = false;

            sockaddr_in from{};
            int fromLength = sizeof(from);
            int received = recvfrom(m_stream, reinterpret_cast<char *>(buffer), sizeof(buffer), 0,
                                    reinterpret_cast<sockaddr *>(&from), &fromLength);
            if (received > 0) {
                handleStreamPacket(buffer, static_cast<size_t>(received), from);
                worked = true;
            }

            fromLength = sizeof(from);
            received = recvfrom(m_discovery, reinterpret_cast<char *>(buffer), sizeof(buffer), 0,
                                reinterpret_cast<sockaddr *>(&from), &fromLength);
            if (received > 0) {
                handleDiscovery(buffer, static_cast<size_t>(received), from);
                worked = true;
            }

            if (!worked) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
    }

    void handleStreamPacket(const uint8_t *data, size_t size, const sockaddr_in &from) {
        if (size < 32 || readU32(data) != kMagicPose) return;

        switch (readU16(data + 6)) {
        case kPacketPose: {
            if (size < 72) return;
            std::lock_guard<std::mutex> guard(g_head.lock);
            g_head.orientation[0] = readF32(data + 32);
            g_head.orientation[1] = readF32(data + 36);
            g_head.orientation[2] = readF32(data + 40);
            g_head.orientation[3] = readF32(data + 44);
            g_head.position[0] = readF32(data + 48);
            g_head.position[1] = readF32(data + 52);
            g_head.position[2] = readF32(data + 56);
            g_head.angularVelocity[0] = readF32(data + 60);
            g_head.angularVelocity[1] = readF32(data + 64);
            g_head.angularVelocity[2] = readF32(data + 68);
            const float ipd = readF32(data + 24);
            if (ipd > 0.03f && ipd < 0.1f) {
                g_head.ipd = ipd;
            }
            g_head.phoneAddress = from;
            g_head.havePhone = true;
            g_head.lastPacketMs = nowMillis();
            g_head.valid = true;
            g_encoder.setTarget(from);

            applyControllerRecords(data, size);
            applyHandRecords(data, size);
            break;
        }
        case kPacketHello: {
            if (size < 41) return;
            bool bitrateChanged = false;
            {
                std::lock_guard<std::mutex> guard(g_request.lock);
                const uint16_t width = readU16(data + 32);
                const uint16_t height = readU16(data + 34);
                if (width >= 640 && height >= 480) {
                    const uint16_t bitrate = readU16(data + 38);
                    if (bitrate >= 1000 && bitrate != g_request.bitrateKbps) {
                        bitrateChanged = true;
                    }
                    g_request.width = width;
                    g_request.height = height;
                    g_request.fps = readU16(data + 36);
                    g_request.bitrateKbps = bitrate;
                }
            }
            if (bitrateChanged) {
                g_encoderRestart = true;
            }
            sendAck(from);
            return;
        }
        case kPacketPing: {
            if (size < 40) return;
            sendPong(from, readU64(data + 32));
            return;
        }
        case kPacketBitrate: {
            if (size < 34) return;
            const uint16_t bitrate = readU16(data + 32);
            if (bitrate < 1000) return;
            bool changed = false;
            {
                std::lock_guard<std::mutex> guard(g_request.lock);
                if (g_request.bitrateKbps != bitrate) {
                    g_request.bitrateKbps = bitrate;
                    changed = true;
                }
            }
            if (changed) {
                g_encoderRestart = true;
                if (vr::VRDriverLog()) {
                    vr::VRDriverLog()->Log("Crab the VR: bitrate changed");
                }
            }
            return;
        }
        case kPacketProfile: {
            if (size < 64) return;
            const uint16_t screenWidth = readU16(data + 32);
            const uint16_t screenHeight = readU16(data + 34);
            const uint16_t refresh = readU16(data + 52);
            bool restartEncoder = false;
            {
                std::lock_guard<std::mutex> guard(g_profile.lock);
                g_profile.screenWidth = screenWidth;
                g_profile.screenHeight = screenHeight;
                g_profile.distortionK1 = readF32(data + 36);
                g_profile.distortionK2 = readF32(data + 40);
                g_profile.ipd = readF32(data + 44);
                g_profile.supersampling = readF32(data + 48);
                g_profile.refreshRate = refresh;
                g_profile.fovCrop = readF32(data + 56);
                g_profile.vignette = readF32(data + 60);
                g_profile.lastPacketMs = nowMillis();
                g_profile.valid = true;
            }
            {
                std::lock_guard<std::mutex> guard(g_request.lock);
                if (screenWidth >= 640 && screenHeight >= 480 &&
                    (g_request.width != screenWidth || g_request.height != screenHeight)) {
                    g_request.width = screenWidth;
                    g_request.height = screenHeight;
                    restartEncoder = true;
                }
                if (refresh >= 60 && g_request.fps != refresh) {
                    g_request.fps = refresh;
                    restartEncoder = true;
                }
            }
            if (restartEncoder) {
                g_encoderRestart = true;
            }
            return;
        }
        case kPacketBye: {
            std::lock_guard<std::mutex> guard(g_head.lock);
            g_head.havePhone = false;
            g_head.valid = false;
            g_encoder.clearTarget();
            return;
        }
        default:
            break;
        }
    }

    void handleDiscovery(const uint8_t *data, size_t size, const sockaddr_in &from) {
        if (size < 7 || readU32(data) != kMagicDiscover) return;

        std::string packet;
        appendU32(packet, kMagicDiscoverReply);
        appendU16(packet, kProtocolVersion);
        appendU16(packet, kStreamPort);

        std::string name = computerName();
        if (name.size() > 120) name.resize(120);
        packet.push_back(static_cast<char>(0x01)); // flags: SteamVR is running
        packet.push_back(static_cast<char>(name.size() & 0xFF));
        packet.append(name);

        sendto(m_discovery, packet.data(), static_cast<int>(packet.size()), 0,
               reinterpret_cast<const sockaddr *>(&from), sizeof(from));
    }

    void sendAck(const sockaddr_in &from) {
        std::string packet;
        appendU32(packet, kMagicReply);
        appendU16(packet, kProtocolVersion);
        appendU16(packet, kReplyAck);
        appendU64(packet, nowMillis() * 1000);

        std::string name = computerName();
        if (name.size() > 200) name.resize(200);
        packet.push_back(static_cast<char>(name.size() & 0xFF));
        packet.append(name);
        appendU16(packet, 0);
        appendU16(packet, 0);

        sendto(m_stream, packet.data(), static_cast<int>(packet.size()), 0,
               reinterpret_cast<const sockaddr *>(&from), sizeof(from));
    }

    void sendPong(const sockaddr_in &from, uint64_t clientTimeUs) {
        std::string packet;
        appendU32(packet, kMagicReply);
        appendU16(packet, kProtocolVersion);
        appendU16(packet, kReplyPong);
        appendU64(packet, clientTimeUs);
        packet.push_back(0);
        appendU16(packet, 0);
        appendU16(packet, 0);

        sendto(m_stream, packet.data(), static_cast<int>(packet.size()), 0,
               reinterpret_cast<const sockaddr *>(&from), sizeof(from));
    }

    SOCKET m_stream = INVALID_SOCKET;
    SOCKET m_discovery = INVALID_SOCKET;
    std::thread m_thread;
    std::atomic<bool> m_running{false};
};

// ---------------------------------------------------------------------------
// The controllers
// ---------------------------------------------------------------------------

/// One paired Nintendo pad, presented to SteamVR as a Vive-style controller so
/// Steam Input and every VR game that understands tracked controllers can use
/// it without a custom profile.
class JoyVRController : public vr::ITrackedDeviceServerDriver {
public:
    explicit JoyVRController(uint8_t slot) : m_slot(slot) {}

    // ITrackedDeviceServerDriver

    vr::EVRInitError Activate(uint32_t unObjectId) override {
        m_deviceId = unObjectId;

        vr::CVRPropertyHelpers *properties = vr::VRProperties();
        m_container = properties->TrackedDeviceToPropertyContainer(m_deviceId);

        const uint8_t role = currentRole();

        properties->SetStringProperty(m_container, vr::Prop_TrackingSystemName_String, "joyvr");
        properties->SetStringProperty(m_container, vr::Prop_ManufacturerName_String, "Nintendo");
        properties->SetStringProperty(m_container, vr::Prop_ModelNumber_String, modelName(role));
        properties->SetStringProperty(m_container, vr::Prop_SerialNumber_String, serialNumber().c_str());
        properties->SetStringProperty(m_container, vr::Prop_ControllerType_String, "vive_controller");
        properties->SetInt32Property(m_container, vr::Prop_DeviceClass_Int32, vr::TrackedDeviceClass_Controller);
        properties->SetInt32Property(m_container, vr::Prop_ControllerRoleHint_Int32, roleHint(role));
        properties->SetBoolProperty(m_container, vr::Prop_WillDriftInYaw_Bool, false);
        properties->SetBoolProperty(m_container, vr::Prop_DeviceProvidesBatteryStatus_Bool, true);

        m_roleApplied = role;
        createComponents();

        if (vr::VRDriverLog()) {
            vr::VRDriverLog()->Log("Crab the VR: controller device activated");
        }
        return vr::VRInitError_None;
    }

    void Deactivate() override {
        m_deviceId = vr::k_unTrackedDeviceIndexInvalid;
    }

    void EnterStandby() override {}

    void *GetComponent(const char *pchComponentNameAndVersion) override {
        (void)pchComponentNameAndVersion;
        return nullptr;
    }

    void DebugRequest(const char *pchRequest, char *pchResponseBuffer, uint32_t unResponseBufferSize) override {
        (void)pchRequest;
        if (pchResponseBuffer == nullptr || unResponseBufferSize == 0) return;
        pchResponseBuffer[0] = '\0';
    }

    vr::DriverPose_t GetPose() override {
        vr::DriverPose_t pose = {};
        pose.qWorldFromDriverRotation.w = 1.0;
        pose.qDriverFromHeadRotation.w = 1.0;
        pose.qRotation.w = 1.0;
        pose.result = vr::TrackingResult_Running_OutOfRange;
        return pose;
    }

    uint32_t deviceId() const { return m_deviceId; }

    /// Called from the server's frame loop with the head pose of the moment.
    void update(const HeadPose &head) {
        if (m_deviceId == vr::k_unTrackedDeviceIndexInvalid) return;

        uint8_t role = 2;
        uint16_t buttons = 0;
        float leftX = 0.0f;
        float leftY = 0.0f;
        float rightX = 0.0f;
        float rightY = 0.0f;
        float leftTrigger = 0.0f;
        float rightTrigger = 0.0f;
        uint8_t battery = 255;
        bool connected = false;
        const bool isHand = m_slot >= 4;
        float handGrip[3] = {0.0f, 0.0f, 0.0f};
        double handAimRotation[4] = {0.0, 0.0, 0.0, 1.0};

        {
            const uint64_t now = nowMillis();
            const uint64_t timeout = isHand ? kHandTimeoutMs : kControllerTimeoutMs;
            std::lock_guard<std::mutex> guard(g_controllers.lock);
            role = g_controllers.role[m_slot];
            buttons = g_controllers.buttons[m_slot];
            leftX = g_controllers.leftStick[m_slot][0];
            leftY = g_controllers.leftStick[m_slot][1];
            rightX = g_controllers.rightStick[m_slot][0];
            rightY = g_controllers.rightStick[m_slot][1];
            leftTrigger = g_controllers.leftTrigger[m_slot];
            rightTrigger = g_controllers.rightTrigger[m_slot];
            battery = g_controllers.battery[m_slot];
            handGrip[0] = g_controllers.handGrip[m_slot][0];
            handGrip[1] = g_controllers.handGrip[m_slot][1];
            handGrip[2] = g_controllers.handGrip[m_slot][2];
            handAimRotation[0] = g_controllers.handAimRotation[m_slot][0];
            handAimRotation[1] = g_controllers.handAimRotation[m_slot][1];
            handAimRotation[2] = g_controllers.handAimRotation[m_slot][2];
            handAimRotation[3] = g_controllers.handAimRotation[m_slot][3];
            connected = g_controllers.present[m_slot] &&
                        now - g_controllers.lastPacketMs[m_slot] < timeout;
            if (!connected) {
                g_controllers.present[m_slot] = false;
            }
        }

        if (role != m_roleApplied) {
            m_roleApplied = role;
            vr::VRProperties()->SetInt32Property(m_container, vr::Prop_ControllerRoleHint_Int32, roleHint(role));
        }

        if (battery != m_battery) {
            m_battery = battery;
            if (battery <= 100) {
                vr::VRProperties()->SetFloatProperty(m_container, vr::Prop_DeviceBatteryPercentage_Float,
                                                      battery / 100.0f);
            }
        }

        const bool hasLeftStick = std::fabs(leftX) + std::fabs(leftY) > 0.01f;
        const float stickX = hasLeftStick ? leftX : rightX;
        const float stickY = hasLeftStick ? leftY : rightY;
        const float trigger = std::max(leftTrigger, rightTrigger);

        const bool a = (buttons & (1u << 0)) != 0;
        const bool b = (buttons & (1u << 1)) != 0;
        const bool x = (buttons & (1u << 2)) != 0;
        const bool y = (buttons & (1u << 3)) != 0;
        const bool l = (buttons & (1u << 4)) != 0;
        const bool r = (buttons & (1u << 5)) != 0;
        const bool zl = (buttons & (1u << 6)) != 0;
        const bool zr = (buttons & (1u << 7)) != 0;
        const bool plus = (buttons & (1u << 8)) != 0;
        const bool minus = (buttons & (1u << 9)) != 0;
        const bool home = (buttons & (1u << 10)) != 0;

        const bool trackpadClick = isHand ? trigger > 0.9f : a;
        const bool touch = isHand ? trigger > 0.3f : (a || b || x || y);
        const bool gripPressed = isHand ? trigger > 0.35f : (l || r);
        const bool triggerClick = isHand ? trigger > 0.6f : (zl || zr || trigger > 0.5f);

        vr::IVRDriverInput *input = vr::VRDriverInput();
        input->UpdateScalarComponent(m_triggerValue, trigger, 0.0);
        input->UpdateBooleanComponent(m_triggerClick, triggerClick, 0.0);
        input->UpdateBooleanComponent(m_grip, gripPressed, 0.0);
        input->UpdateBooleanComponent(m_menu, plus || minus, 0.0);
        input->UpdateBooleanComponent(m_system, home, 0.0);
        input->UpdateScalarComponent(m_trackpadX, stickX, 0.0);
        input->UpdateScalarComponent(m_trackpadY, stickY, 0.0);
        input->UpdateBooleanComponent(m_trackpadClick, trackpadClick, 0.0);
        input->UpdateBooleanComponent(m_trackpadTouch, touch, 0.0);

        vr::DriverPose_t pose = {};
        pose.poseTimeOffset = 0.0;
        pose.qWorldFromDriverRotation.w = 1.0;
        pose.qDriverFromHeadRotation.w = 1.0;

        if (isHand) {
            double grip[3] = {handGrip[0], handGrip[1], handGrip[2]};
            double rotated[3] = {0.0, 0.0, 0.0};
            rotateVector(head.orientation, grip, rotated);

            double worldRotation[4] = {0.0, 0.0, 0.0, 1.0};
            multiplyQuaternions(head.orientation, handAimRotation, worldRotation);

            pose.vecPosition[0] = head.position[0] + rotated[0];
            pose.vecPosition[1] = kHeadHeightMetres + head.position[1] + rotated[1];
            pose.vecPosition[2] = head.position[2] + rotated[2];
            pose.qRotation.x = worldRotation[0];
            pose.qRotation.y = worldRotation[1];
            pose.qRotation.z = worldRotation[2];
            pose.qRotation.w = worldRotation[3];
        } else {
            // Hands sit in front of the head, slightly to their own side.
            double offset[3] = {0.0, -0.18, -0.30};
            if (role == 0) {
                offset[0] = -0.18;
                offset[1] = -0.12;
                offset[2] = -0.25;
            } else if (role == 1) {
                offset[0] = 0.18;
                offset[1] = -0.12;
                offset[2] = -0.25;
            }

            double rotated[3] = {0.0, 0.0, 0.0};
            rotateVector(head.orientation, offset, rotated);

            pose.qRotation.x = head.orientation[0];
            pose.qRotation.y = head.orientation[1];
            pose.qRotation.z = head.orientation[2];
            pose.qRotation.w = head.orientation[3];
            pose.vecPosition[0] = head.position[0] + rotated[0];
            pose.vecPosition[1] = kHeadHeightMetres + head.position[1] + rotated[1];
            pose.vecPosition[2] = head.position[2] + rotated[2];
        }

        pose.result = connected ? vr::TrackingResult_Running_OK : vr::TrackingResult_Running_OutOfRange;
        pose.poseIsValid = connected;
        pose.shouldApplyHeadModel = false;
        pose.willDriftInYaw = false;
        pose.deviceIsConnected = connected;

        vr::VRServerDriverHost()->TrackedDevicePoseUpdated(m_deviceId, pose, sizeof(vr::DriverPose_t));
    }

private:
    void createComponents() {
        vr::IVRDriverInput *input = vr::VRDriverInput();

        input->CreateBooleanComponent(m_container, "/input/system/click", &m_system);
        input->CreateBooleanComponent(m_container, "/input/application_menu/click", &m_menu);
        input->CreateBooleanComponent(m_container, "/input/grip/click", &m_grip);

        input->CreateScalarComponent(m_container, "/input/trigger/value", &m_triggerValue,
                                     vr::VRScalarType_Absolute, vr::VRScalarUnits_NormalizedOneSided);
        input->CreateBooleanComponent(m_container, "/input/trigger/click", &m_triggerClick);

        input->CreateScalarComponent(m_container, "/input/trackpad/x", &m_trackpadX,
                                     vr::VRScalarType_Absolute, vr::VRScalarUnits_NormalizedTwoSided);
        input->CreateScalarComponent(m_container, "/input/trackpad/y", &m_trackpadY,
                                     vr::VRScalarType_Absolute, vr::VRScalarUnits_NormalizedTwoSided);
        input->CreateBooleanComponent(m_container, "/input/trackpad/click", &m_trackpadClick);
        input->CreateBooleanComponent(m_container, "/input/trackpad/touch", &m_trackpadTouch);
    }

    uint8_t currentRole() const {
        std::lock_guard<std::mutex> guard(g_controllers.lock);
        return g_controllers.role[m_slot];
    }

    std::string serialNumber() const {
        return "joyvr_controller_" + std::to_string(m_slot);
    }

    const char *modelName(uint8_t role) const {
        if (m_slot >= 4) {
            return m_slot == 4 ? "Left hand" : "Right hand";
        }
        switch (role) {
        case 0: return "Joy-Con (L)";
        case 1: return "Joy-Con (R)";
        default: return "Nintendo Controller";
        }
    }

    static int32_t roleHint(uint8_t role) {
        switch (role) {
        case 0: return vr::TrackedControllerRole_LeftHand;
        case 1: return vr::TrackedControllerRole_RightHand;
        default: return vr::TrackedControllerRole_OptOut;
        }
    }

    uint8_t m_slot = 0;
    uint32_t m_deviceId = vr::k_unTrackedDeviceIndexInvalid;
    vr::PropertyContainerHandle_t m_container = vr::k_ulInvalidPropertyContainer;
    uint8_t m_roleApplied = 255;
    uint8_t m_battery = 255;

    vr::VRInputComponentHandle_t m_system = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_menu = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_grip = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_triggerValue = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_triggerClick = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_trackpadX = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_trackpadY = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_trackpadClick = vr::k_ulInvalidInputComponentHandle;
    vr::VRInputComponentHandle_t m_trackpadTouch = vr::k_ulInvalidInputComponentHandle;
};

// ---------------------------------------------------------------------------
// The headset
// ---------------------------------------------------------------------------

class JoyVRHmd : public vr::ITrackedDeviceServerDriver,
                 public vr::IVRDisplayComponent,
                 public vr::IVRVirtualDisplay {
public:
    // ITrackedDeviceServerDriver

    vr::EVRInitError Activate(uint32_t unObjectId) override {
        m_deviceId = unObjectId;

        vr::CVRPropertyHelpers *properties = vr::VRProperties();
        const vr::PropertyContainerHandle_t container =
            properties->TrackedDeviceToPropertyContainer(m_deviceId);
        m_container = container;

        properties->SetStringProperty(container, vr::Prop_TrackingSystemName_String, "joyvr");
        properties->SetStringProperty(container, vr::Prop_ManufacturerName_String, "Crab the VR");
        properties->SetStringProperty(container, vr::Prop_ModelNumber_String, "Crab the VR iPhone");
        properties->SetStringProperty(container, vr::Prop_SerialNumber_String, "joyvr-0001");
        properties->SetFloatProperty(container, vr::Prop_DisplayFrequency_Float, float(kDefaultFPS));
        properties->SetFloatProperty(container, vr::Prop_UserIpdMeters_Float, 0.064f);
        properties->SetFloatProperty(container, vr::Prop_UserHeadToEyeDepthMeters_Float, 0.0f);
        properties->SetFloatProperty(container, vr::Prop_SecondsFromVsyncToPhotons_Float, 0.011f);
        properties->SetBoolProperty(container, vr::Prop_WillDriftInYaw_Bool, false);
        properties->SetBoolProperty(container, vr::Prop_IsOnDesktop_Bool, false);
        properties->SetInt32Property(container, vr::Prop_DeviceClass_Int32, vr::TrackedDeviceClass_HMD);

        m_pose.position = {0.0, 1.6, 0.0};

        m_ipd = 0.0f;
        setIPD(0.064f);

        startEncoder();

        if (vr::VRDriverLog()) {
            vr::VRDriverLog()->Log("Crab the VR: headset activated");
        }
        return vr::VRInitError_None;
    }

    void Deactivate() override {
        g_encoder.stop();
        m_encoderStarted = false;
    }

    void EnterStandby() override {}

    void *GetComponent(const char *pchComponentNameAndVersion) override {
        if (pchComponentNameAndVersion == nullptr) return nullptr;
        if (!std::strcmp(pchComponentNameAndVersion, vr::IVRDisplayComponent_Version)) {
            return static_cast<vr::IVRDisplayComponent *>(this);
        }
        if (!std::strcmp(pchComponentNameAndVersion, vr::IVRVirtualDisplay_Version)) {
            return static_cast<vr::IVRVirtualDisplay *>(this);
        }
        return nullptr;
    }

    void DebugRequest(const char *pchRequest, char *pchResponseBuffer, uint32_t unResponseBufferSize) override {
        if (pchResponseBuffer == nullptr || unResponseBufferSize == 0) return;
        pchResponseBuffer[0] = '\0';
    }

    vr::DriverPose_t GetPose() override {
        vr::DriverPose_t pose = {};
        pose.qWorldFromDriverRotation.w = 1.0;
        pose.qDriverFromHeadRotation.w = 1.0;
        pose.qRotation.w = 1.0;
        pose.deviceIsConnected = true;
        pose.result = vr::TrackingResult_Running_OK;
        return pose;
    }

    // IVRDisplayComponent
    // The phone warps the picture for its own lenses, so the compositor is told
    // about geometry only and distortion is the identity.

    void GetWindowBounds(int32_t *pnX, int32_t *pnY, uint32_t *pnWidth, uint32_t *pnHeight) override {
        if (pnX) *pnX = 0;
        if (pnY) *pnY = 0;
        if (pnWidth) *pnWidth = m_eyeWidth * 2;
        if (pnHeight) *pnHeight = m_eyeHeight;
    }

    bool IsDisplayOnDesktop() override { return false; }
    bool IsDisplayRealDisplay() override { return false; }

    void GetRecommendedRenderTargetSize(uint32_t *pnWidth, uint32_t *pnHeight) override {
        if (pnWidth) *pnWidth = static_cast<uint32_t>(m_eyeWidth * m_supersampling);
        if (pnHeight) *pnHeight = static_cast<uint32_t>(m_eyeHeight * m_supersampling);
    }

    void GetEyeOutputViewport(vr::EVREye eEye, uint32_t *pnX, uint32_t *pnY,
                              uint32_t *pnWidth, uint32_t *pnHeight) override {
        if (pnX) *pnX = (eEye == vr::Eye_Left) ? 0 : m_eyeWidth;
        if (pnY) *pnY = 0;
        if (pnWidth) *pnWidth = m_eyeWidth;
        if (pnHeight) *pnHeight = m_eyeHeight;
    }

    void GetProjectionRaw(vr::EVREye eEye, float *pfLeft, float *pfRight,
                          float *pfTop, float *pfBottom) override {
        (void)eEye;
        const float cropScale = std::max(0.4f, 1.0f - m_fovCrop);
        if (pfLeft) *pfLeft = -1.2f * cropScale;
        if (pfRight) *pfRight = 1.2f * cropScale;
        if (pfTop) *pfTop = -1.2f * cropScale;
        if (pfBottom) *pfBottom = 1.2f * cropScale;
    }

    vr::DistortionCoordinates_t ComputeDistortion(vr::EVREye eEye, float fU, float fV) override {
        (void)eEye;
        vr::DistortionCoordinates_t coordinates = {};
        coordinates.rfRed[0] = fU;
        coordinates.rfRed[1] = fV;
        coordinates.rfGreen[0] = fU;
        coordinates.rfGreen[1] = fV;
        coordinates.rfBlue[0] = fU;
        coordinates.rfBlue[1] = fV;
        return coordinates;
    }

    bool ComputeInverseDistortion(vr::HmdVector2_t *pResult, vr::EVREye eEye,
                                  uint32_t unChannel, float fU, float fV) override {
        (void)eEye;
        (void)unChannel;
        if (!pResult) return false;
        pResult->v[0] = fU;
        pResult->v[1] = fV;
        return true;
    }

    // IVRVirtualDisplay

    void Present(const vr::PresentInfo_t *pPresentInfo, uint32_t unPresentInfoSize) override {
        (void)unPresentInfoSize;
        if (!pPresentInfo) return;

        if (!m_encoderStarted) startEncoder();

        // Duplicate the compositor's shared handle so the encoder thread can
        // close its own copy without touching SteamVR's.
        HANDLE duplicated = nullptr;
        if (!DuplicateHandle(GetCurrentProcess(),
                             reinterpret_cast<HANDLE>(pPresentInfo->backbufferTextureHandle),
                             GetCurrentProcess(), &duplicated, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
            return;
        }

        SharedTextureFrame frame;
        frame.handle = duplicated;
        frame.vsyncSeconds = pPresentInfo->flVSyncTimeInSeconds;
        frame.number = pPresentInfo->nFrameId;
        g_encoder.submit(frame);
    }

    void WaitForPresent() override {}

    bool GetTimeSinceLastVsync(float *pfSecondsSinceLastVsync, uint64_t *pulFrameCounter) override {
        (void)pfSecondsSinceLastVsync;
        (void)pulFrameCounter;
        return false;
    }

    uint32_t deviceId() const { return m_deviceId; }

    /// Rebuilds the encoder with the bitrate currently in g_request.
    void restartEncoder() {
        g_encoder.stop();
        m_encoderStarted = false;
        startEncoder();
    }

    /// The phone's IPD moves the two virtual eyes apart.
    void setIPD(float ipd) {
        if (m_deviceId == vr::k_unTrackedDeviceIndexInvalid) return;
        if (m_container == vr::k_ulInvalidPropertyContainer) return;
        if (std::fabs(ipd - m_ipd) < 0.0005f) return;

        m_ipd = ipd;
        vr::VRProperties()->SetFloatProperty(m_container, vr::Prop_UserIpdMeters_Float, ipd);

        vr::HmdMatrix34_t left = {};
        left.m[0][0] = 1.0f;
        left.m[1][1] = 1.0f;
        left.m[2][2] = 1.0f;
        left.m[0][3] = -ipd * 0.5f;

        vr::HmdMatrix34_t right = {};
        right.m[0][0] = 1.0f;
        right.m[1][1] = 1.0f;
        right.m[2][2] = 1.0f;
        right.m[0][3] = ipd * 0.5f;

        vr::VRServerDriverHost()->SetDisplayEyeToHead(m_deviceId, left, right);
    }

    /// A saved profile: the eye offset, the cropped projection and the render
    /// scale the phone expects. The vignette itself is drawn on the phone.
    void applyProfile(float ipd, float fovCrop, float supersampling, uint16_t refreshRate) {
        setIPD(ipd);

        const float crop = std::max(0.0f, std::min(0.6f, fovCrop));
        if (std::fabs(crop - m_fovCrop) > 0.001f) {
            m_fovCrop = crop;
        }

        const float scale = std::max(0.5f, std::min(2.0f, supersampling));
        if (std::fabs(scale - m_supersampling) > 0.001f) {
            m_supersampling = scale;
        }

        if (refreshRate >= 60 && refreshRate != m_refreshRate) {
            m_refreshRate = refreshRate;
            if (m_container != vr::k_ulInvalidPropertyContainer) {
                vr::VRProperties()->SetFloatProperty(m_container,
                                                     vr::Prop_DisplayFrequency_Float,
                                                     static_cast<float>(refreshRate));
            }
        }
    }

private:
    void startEncoder() {
        if (m_encoderStarted) return;

        uint32_t totalWidth = kDefaultEyeWidth * 2;
        uint32_t totalHeight = kDefaultEyeHeight;
        uint32_t fps = kDefaultFPS;
        uint32_t bitrate = kDefaultBitrateKbps;

        {
            std::lock_guard<std::mutex> guard(g_request.lock);
            if (g_request.width >= 640 && g_request.height >= 480) {
                totalWidth = g_request.width;
                totalHeight = g_request.height;
                fps = g_request.fps > 0 ? g_request.fps : kDefaultFPS;
                bitrate = g_request.bitrateKbps > 0 ? g_request.bitrateKbps : kDefaultBitrateKbps;
            }
        }

        m_eyeWidth = totalWidth / 2;
        m_eyeHeight = totalHeight;

        m_encoderStarted = g_encoder.start(totalWidth, totalHeight, fps, bitrate);
        if (vr::VRDriverLog()) {
            vr::VRDriverLog()->Log(m_encoderStarted ? "Crab the VR: video encoder started"
                                                   : "Crab the VR: video encoder could not start");
        }
    }

    uint32_t m_deviceId = vr::k_unTrackedDeviceIndexInvalid;
    vr::PropertyContainerHandle_t m_container = vr::k_ulInvalidPropertyContainer;
    float m_ipd = 0.064f;
    float m_fovCrop = 0.0f;
    float m_supersampling = 1.0f;
    uint16_t m_refreshRate = 90;
    uint32_t m_eyeWidth = kDefaultEyeWidth;
    uint32_t m_eyeHeight = kDefaultEyeHeight;
    bool m_encoderStarted = false;

    struct ResetPose {
        double position[3] = {0.0, 1.6, 0.0};
    } m_pose;
};

// ---------------------------------------------------------------------------
// The provider
// ---------------------------------------------------------------------------

class JoyVRProvider : public vr::IServerTrackedDeviceProvider {
public:
    vr::EVRInitError Init(vr::IVRDriverContext *pDriverContext) override {
        VR_INIT_SERVER_DRIVER_CONTEXT(pDriverContext);

        if (vr::VRDriverLog()) {
            vr::VRDriverLog()->Log("Crab the VR: starting the PC companion");
        }

        if (!m_server.start()) {
            if (vr::VRDriverLog()) {
                vr::VRDriverLog()->Log("Crab the VR: could not open UDP 8930/8931");
            }
            return vr::VRInitError_Driver_Failed;
        }

        vr::VRServerDriverHost()->TrackedDeviceAdded("joyvr_hmd",
                                                     vr::TrackedDeviceClass_HMD,
                                                     &m_hmd);
        return vr::VRInitError_None;
    }

    void Cleanup() override {
        m_server.stop();
        g_encoder.stop();
        VR_CLEANUP_SERVER_DRIVER_CONTEXT();
    }

    const char *const *GetInterfaceVersions() override {
        static const char *const versions[] = {
            vr::ITrackedDeviceServerDriver_Version,
            nullptr
        };
        return versions;
    }

    void RunFrame() override {
        if (g_encoderRestart.exchange(false)) {
            m_hmd.restartEncoder();
        }

        double orientation[4] = {0.0, 0.0, 0.0, 1.0};
        double position[3] = {0.0, 0.0, 0.0};
        double angularVelocity[3] = {0.0, 0.0, 0.0};
        float headIPD = 0.064f;
        bool headValid = false;

        {
            std::lock_guard<std::mutex> guard(g_head.lock);
            if (g_head.valid) {
                std::memcpy(orientation, g_head.orientation, sizeof(orientation));
                std::memcpy(position, g_head.position, sizeof(position));
                std::memcpy(angularVelocity, g_head.angularVelocity, sizeof(angularVelocity));
                headIPD = g_head.ipd;
                headValid = true;
            }
        }

        if (headValid) {
            m_hmd.setIPD(headIPD);
        }

        float profileIPD = 0.064f;
        float profileCrop = 0.0f;
        float profileSupersampling = 1.0f;
        uint16_t profileRefresh = 90;
        bool profileValid = false;
        {
            std::lock_guard<std::mutex> guard(g_profile.lock);
            if (g_profile.valid) {
                profileIPD = g_profile.ipd;
                profileCrop = g_profile.fovCrop;
                profileSupersampling = g_profile.supersampling;
                profileRefresh = g_profile.refreshRate;
                profileValid = true;
            }
        }
        if (profileValid) {
            m_hmd.applyProfile(profileIPD, profileCrop, profileSupersampling, profileRefresh);
        }

        HeadPose head;
        head.valid = headValid;
        std::memcpy(head.orientation, orientation, sizeof(orientation));
        std::memcpy(head.position, position, sizeof(position));

        updateControllers(head);

        if (!headValid) return;

        vr::DriverPose_t pose = {};
        pose.poseTimeOffset = 0.0;
        pose.qWorldFromDriverRotation.w = 1.0;
        pose.qDriverFromHeadRotation.w = 1.0;
        pose.qRotation.x = orientation[0];
        pose.qRotation.y = orientation[1];
        pose.qRotation.z = orientation[2];
        pose.qRotation.w = orientation[3];
        pose.vecPosition[0] = position[0];
        pose.vecPosition[1] = kHeadHeightMetres + position[1];
        pose.vecPosition[2] = position[2];
        pose.vecAngularVelocity[0] = angularVelocity[0];
        pose.vecAngularVelocity[1] = angularVelocity[1];
        pose.vecAngularVelocity[2] = angularVelocity[2];
        pose.result = vr::TrackingResult_Running_OK;
        pose.poseIsValid = true;
        pose.shouldApplyHeadModel = false;
        pose.willDriftInYaw = false;
        pose.deviceIsConnected = true;

        vr::VRServerDriverHost()->TrackedDevicePoseUpdated(m_hmd.deviceId(), pose,
                                                           sizeof(vr::DriverPose_t));
    }

    bool ShouldBlockStandbyMode() override { return false; }
    void EnterStandby() override {}
    void LeaveStandby() override {}

private:
    /// Adds a controller the first time the phone reports it and refreshes the
    /// ones already added.
    void updateControllers(const HeadPose &head) {
        const uint64_t now = nowMillis();

        for (uint8_t slot = 0; slot < kMaxControllerSlots; ++slot) {
            bool present = false;
            {
                const uint64_t timeout = slot >= 4 ? kHandTimeoutMs : kControllerTimeoutMs;
                std::lock_guard<std::mutex> guard(g_controllers.lock);
                present = g_controllers.present[slot] &&
                          now - g_controllers.lastPacketMs[slot] < timeout;
            }

            if (present && !m_controllers[slot]) {
                auto controller = std::make_unique<JoyVRController>(slot);
                const std::string serial = "joyvr_controller_" + std::to_string(slot);
                if (vr::VRServerDriverHost()->TrackedDeviceAdded(serial.c_str(),
                                                                vr::TrackedDeviceClass_Controller,
                                                                controller.get())) {
                    m_controllers[slot] = std::move(controller);
                }
            }

            if (m_controllers[slot]) {
                m_controllers[slot]->update(head);
            }
        }
    }

    std::unique_ptr<JoyVRController> m_controllers[4];

    PoseServer m_server;
    JoyVRHmd m_hmd;
};

JoyVRProvider g_provider;

} // namespace

// ---------------------------------------------------------------------------
// Entry point SteamVR looks for
// ---------------------------------------------------------------------------

#if defined(_WIN32)
#define JOYVR_EXPORT extern "C" __declspec(dllexport)
#else
#define JOYVR_EXPORT extern "C" __attribute__((visibility("default")))
#endif

JOYVR_EXPORT void *HmdDriverFactory(const char *pInterfaceName, int *pReturnCode) {
    if (pInterfaceName != nullptr &&
        std::strcmp(pInterfaceName, vr::IServerTrackedDeviceProvider_Version) == 0) {
        return &g_provider;
    }
    if (pReturnCode != nullptr) {
        *pReturnCode = vr::VRInitError_Init_InterfaceNotFound;
    }
    return nullptr;
}
