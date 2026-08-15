#pragma once

#include "remote_canvas/protocol.hpp"

#include <optional>
#include <string>
#include <vector>

namespace remote_canvas {

class DeviceRegistry {
public:
    [[nodiscard]] bool add(DeviceIdentity identity);
    [[nodiscard]] bool contains(const std::string& device_id) const;
    [[nodiscard]] const std::vector<DeviceIdentity>& devices() const noexcept;

private:
    std::vector<DeviceIdentity> devices_;
};

class HostApplication {
public:
    explicit HostApplication(std::string host_name);

    [[nodiscard]] int run_demo();

private:
    std::string host_name_;
    DeviceRegistry registry_;
};

}  // namespace remote_canvas
