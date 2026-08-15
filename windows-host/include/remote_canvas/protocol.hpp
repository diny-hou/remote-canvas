#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace remote_canvas {

inline constexpr auto kProtocolVersion = "remote-canvas/1";

struct DeviceIdentity {
    std::string id;
    std::string display_name;
    std::string public_key;
};

struct SessionCapabilities {
    bool h264_video = true;
    bool pointer_input = true;
    bool text_input = true;
    bool semantic_ui = false;
};

struct PointerInput {
    std::uint64_t sequence = 0;
    double normalized_x = 0;
    double normalized_y = 0;
    enum class Action { move, primary_click, secondary_click, scroll } action = Action::move;
    double scroll_delta = 0;
};

}  // namespace remote_canvas
