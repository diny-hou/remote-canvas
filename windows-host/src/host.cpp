#include "remote_canvas/host.hpp"

#include <algorithm>
#include <iostream>
#include <utility>

namespace remote_canvas {

bool DeviceRegistry::add(DeviceIdentity identity) {
    if (identity.id.empty() || identity.display_name.empty() || identity.public_key.empty()) {
        return false;
    }
    if (contains(identity.id)) {
        return false;
    }
    devices_.push_back(std::move(identity));
    return true;
}

bool DeviceRegistry::contains(const std::string& device_id) const {
    return std::ranges::any_of(devices_, [&](const auto& device) {
        return device.id == device_id;
    });
}

const std::vector<DeviceIdentity>& DeviceRegistry::devices() const noexcept {
    return devices_;
}

HostApplication::HostApplication(std::string host_name)
    : host_name_(std::move(host_name)) {}

int HostApplication::run_demo() {
    const auto added = registry_.add({
        "demo-ios-client",
        "Takumi's iPhone",
        "preview-p256-public-key",
    });

    std::cout << "RemoteCanvas host " << host_name_ << '\n';
    std::cout << "protocol=" << kProtocolVersion << '\n';
    std::cout << "registered_devices=" << registry_.devices().size() << '\n';
    std::cout << "pairing_result=" << (added ? "accepted" : "rejected") << '\n';
#ifdef _WIN32
    std::cout << "platform=windows; capture_backend=dxgi-pending" << '\n';
#else
    std::cout << "platform=development; capture_backend=mock" << '\n';
#endif
    return added ? 0 : 1;
}

}  // namespace remote_canvas
