#ifndef YULLO_KEYCHAIN_INTERACTION_H
#define YULLO_KEYCHAIN_INTERACTION_H

#include <Security/SecKeychain.h>

// Legacy file-keychain items do not honor the per-query no-UI policy alone.
// Keep the compatibility APIs and their deprecation exception in this C shim.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline OSStatus YulloGetKeychainInteraction(Boolean *allowed) {
    return SecKeychainGetUserInteractionAllowed(allowed);
}
static inline OSStatus YulloSetKeychainInteraction(Boolean allowed) {
    return SecKeychainSetUserInteractionAllowed(allowed);
}
#pragma clang diagnostic pop

#endif
