#include "remote_canvas/host.hpp"

#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    if (argc != 2 || std::string_view(argv[1]) != "--demo") {
        std::cerr << "usage: remote_canvas_host --demo\n";
        return 64;
    }

    remote_canvas::HostApplication host("Home PC");
    return host.run_demo();
}
