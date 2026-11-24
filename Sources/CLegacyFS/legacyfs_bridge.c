#include "legacyfs_bridge.h"

int montserrat_legacyfs_linked(void) {
    return legacyfs_version() != 0;
}
