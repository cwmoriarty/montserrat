#include "apple_explorer_bridge.h"

int montserrat_apple_explorer_linked(void) {
    return aex_version() != 0;
}
