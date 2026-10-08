#pragma once

#include <algorithm>
#include <arpa/inet.h>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/socket.h>
#include <sys/mount.h>
#include <initializer_list>
#include <optional>
#include <string>
#include <vector>

#import <DiskArbitration/DiskArbitration.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include "TorrentStorageKind.hpp"


static std::string TDTrim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) { return {}; }
    const auto last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

static bool TDIsVPNAdapter(const std::string &name) {
    return name.rfind("utun", 0) == 0
        || name.rfind("tun", 0) == 0
        || name.rfind("tap", 0) == 0
        || name.rfind("ppp", 0) == 0
        || name.rfind("ipsec", 0) == 0;
}

static bool TDIsVirtualAdapter(const std::string &name) {
    return TDIsVPNAdapter(name)
        || name.rfind("bridge", 0) == 0
        || name.rfind("awdl", 0) == 0
        || name.rfind("llw", 0) == 0
        || name.rfind("gif", 0) == 0
        || name.rfind("stf", 0) == 0
        || name.rfind("anpi", 0) == 0
        || name.rfind("ap", 0) == 0;
}

static std::vector<std::string> TDActiveVirtualAdapterNames() {
    std::vector<std::string> result;
    struct ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) { return result; }

    for (struct ifaddrs *entry = interfaces; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr
            || (entry->ifa_flags & IFF_UP) == 0
            || (entry->ifa_flags & IFF_RUNNING) == 0
            || (entry->ifa_flags & IFF_LOOPBACK) != 0
            || entry->ifa_name == nullptr) {
            continue;
        }
        const std::string name(entry->ifa_name);
        if (TDIsVPNAdapter(name)
            && std::find(result.begin(), result.end(), name) == result.end()) {
            result.push_back(name);
        }
    }
    freeifaddrs(interfaces);
    return result;
}

static bool TDNetworkInterfaceTokenIsUsable(const std::string &rawToken) {
    const std::string token = TDTrim(rawToken);
    if (token.empty() || token == "all") { return !token.empty(); }

    in_addr ipv4{};
    in6_addr ipv6{};
    if (inet_pton(AF_INET, token.c_str(), &ipv4) == 1
        || inet_pton(AF_INET6, token.c_str(), &ipv6) == 1) {
        return true;
    }
    return if_nametoindex(token.c_str()) != 0;
}

// Explicit bindings may be interface names (including utun/tun VPN devices),
// literal addresses, or the libtorrent "all" token. Validate every item in a
// comma-separated list so a typo cannot silently fall back to another route.
static bool TDNetworkInterfaceIsUsable(const std::string &rawValue) {
    const std::string value = TDTrim(rawValue);
    if (value.empty()) { return false; }
    std::size_t start = 0;
    while (start <= value.size()) {
        const std::size_t separator = value.find(',', start);
        const std::string token = value.substr(
            start, separator == std::string::npos ? std::string::npos : separator - start);
        if (!TDNetworkInterfaceTokenIsUsable(token)) { return false; }
        if (separator == std::string::npos) { break; }
        start = separator + 1;
    }
    return true;
}

// Return active physical IPv4 adapters in preference order. Virtual tunnel
// adapters can be up while still lacking a route to public tracker/peer
// addresses, so they should not be selected for the automatic bind.
static std::vector<std::string> TDActiveIPv4Addresses() {
    std::vector<std::string> physical;
    std::vector<std::string> fallback;
    struct ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) { return {}; }

    for (struct ifaddrs *entry = interfaces; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr
            || entry->ifa_addr->sa_family != AF_INET
            || (entry->ifa_flags & IFF_UP) == 0
            || (entry->ifa_flags & IFF_RUNNING) == 0
            || (entry->ifa_flags & IFF_LOOPBACK) != 0
            || entry->ifa_name == nullptr) {
            continue;
        }
        const std::string name(entry->ifa_name);
        if (TDIsVirtualAdapter(name)) { continue; }

        char addressBuffer[INET_ADDRSTRLEN] = {};
        const auto *address = reinterpret_cast<const sockaddr_in *>(entry->ifa_addr);
        if (inet_ntop(AF_INET, &address->sin_addr, addressBuffer, sizeof(addressBuffer)) == nullptr) {
            continue;
        }
        const std::string value(addressBuffer);
        auto &target = name.rfind("en", 0) == 0 ? physical : fallback;
        if (std::find(target.begin(), target.end(), value) == target.end()) {
            target.push_back(value);
        }
    }
    freeifaddrs(interfaces);
    if (!physical.empty()) { return physical; }
    return fallback;
}

// Return active physical IPv6 adapters in preference order. Do not bind
// link-local addresses: they require an interface scope and are not useful
// for public tracker/peer connections. Global and unique-local addresses are
// both retained so local and IPv6-capable swarms can use the same session.
static std::vector<std::string> TDActiveIPv6Addresses() {
    std::vector<std::string> physical;
    std::vector<std::string> fallback;
    struct ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) { return {}; }

    for (struct ifaddrs *entry = interfaces; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr
            || entry->ifa_addr->sa_family != AF_INET6
            || (entry->ifa_flags & IFF_UP) == 0
            || (entry->ifa_flags & IFF_RUNNING) == 0
            || (entry->ifa_flags & IFF_LOOPBACK) != 0
            || entry->ifa_name == nullptr) {
            continue;
        }
        const std::string name(entry->ifa_name);
        if (TDIsVirtualAdapter(name)) { continue; }

        const auto *address = reinterpret_cast<const sockaddr_in6 *>(entry->ifa_addr);
        if (IN6_IS_ADDR_UNSPECIFIED(&address->sin6_addr)
            || IN6_IS_ADDR_LOOPBACK(&address->sin6_addr)
            || IN6_IS_ADDR_MULTICAST(&address->sin6_addr)
            || IN6_IS_ADDR_LINKLOCAL(&address->sin6_addr)) {
            continue;
        }

        char addressBuffer[INET6_ADDRSTRLEN] = {};
        if (inet_ntop(AF_INET6, &address->sin6_addr, addressBuffer, sizeof(addressBuffer)) == nullptr) {
            continue;
        }
        const std::string value(addressBuffer);
        auto &target = name.rfind("en", 0) == 0 ? physical : fallback;
        if (std::find(target.begin(), target.end(), value) == target.end()) {
            target.push_back(value);
        }
    }
    freeifaddrs(interfaces);
    if (!physical.empty()) { return physical; }
    return fallback;
}

static bool TDParseAddress(const std::string &text, lt::address &result) {
    lt::error_code ec;
    result = lt::make_address(TDTrim(text), ec);
    return !ec;
}

static bool TDParseEndpoint(const std::string &raw, lt::tcp::endpoint &result) {
    const std::string value = TDTrim(raw);
    if (value.empty()) { return false; }

    std::string host;
    std::string portText;
    if (value.front() == '[') {
        const auto close = value.find(']');
        if (close == std::string::npos || close + 2 > value.size()
            || value[close + 1] != ':') {
            return false;
        }
        host = value.substr(1, close - 1);
        portText = value.substr(close + 2);
    } else {
        const auto colon = value.rfind(':');
        if (colon == std::string::npos || value.find(':') != colon) { return false; }
        host = value.substr(0, colon);
        portText = value.substr(colon + 1);
    }

    lt::address address;
    if (!TDParseAddress(host, address)) { return false; }
    int port = 0;
    try {
        std::size_t consumed = 0;
        port = std::stoi(portText, &consumed);
        if (consumed != portText.size()) { return false; }
    } catch (...) {
        return false;
    }
    if (port < 1 || port > 65'535) { return false; }
    result = lt::tcp::endpoint(address, static_cast<std::uint16_t>(port));
    return true;
}

static bool TDHasSupportedScheme(const std::string &raw,
                                 std::initializer_list<const char *> schemes) {
    const std::string value = TDTrim(raw);
    const auto separator = value.find("://");
    if (separator == std::string::npos || separator == 0 || value.find_first_of(" \t\r\n") != std::string::npos) {
        return false;
    }
    std::string scheme = value.substr(0, separator);
    std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return std::any_of(schemes.begin(), schemes.end(), [&](const char *candidate) {
        return scheme == candidate;
    });
}

static bool TDParseBlockedRange(const std::string &raw, lt::address &first, lt::address &last) {
    std::string value = TDTrim(raw.substr(0, raw.find('#')));
    if (value.empty()) { return false; }
    const auto dash = value.find('-');
    if (dash != std::string::npos) {
        return TDParseAddress(value.substr(0, dash), first)
            && TDParseAddress(value.substr(dash + 1), last)
            && first.is_v4() == last.is_v4();
    }
    const auto slash = value.find('/');
    if (slash == std::string::npos) {
        return TDParseAddress(value, first) && (last = first, true);
    }
    lt::address address;
    if (!TDParseAddress(value.substr(0, slash), address)) { return false; }
    int prefix = 0;
    try { prefix = std::stoi(value.substr(slash + 1)); } catch (...) { return false; }
    if (address.is_v4()) {
        if (prefix < 0 || prefix > 32) { return false; }
        const std::uint32_t mask = prefix == 0 ? 0 : 0xffffffffu << (32 - prefix);
        const std::uint32_t base = address.to_v4().to_uint() & mask;
        first = lt::address_v4(base);
        last = lt::address_v4(base | ~mask);
        return true;
    }
    if (prefix < 0 || prefix > 128) { return false; }
    auto low = address.to_v6().to_bytes();
    auto high = low;
    for (int index = 0; index < 16; ++index) {
        const int remaining = prefix - index * 8;
        const std::uint8_t mask = remaining >= 8 ? 0xff : remaining <= 0 ? 0 : static_cast<std::uint8_t>(0xff << (8 - remaining));
        low[index] &= mask;
        high[index] |= static_cast<std::uint8_t>(~mask);
    }
    first = lt::address_v6(low);
    last = lt::address_v6(high);
    return true;
}

static NSString *TDNSString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data()
                                    length:value.size()
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

static std::string TDStdString(NSString *value) {
    if (value == nil) { return {}; }
    const char *utf8 = value.UTF8String;
    return utf8 != nullptr ? std::string(utf8) : std::string();
}

// Resolve a destination path to its mounted volume. The destination may not
// exist yet, so walk up to the nearest existing parent before calling statfs.
static std::optional<std::string> TDVolumeMountPathForStorageLookup(std::string path) {
    if (path.empty()) { return std::nullopt; }

    while (true) {
        struct statfs volume = {};
        if (statfs(path.c_str(), &volume) == 0) {
            return std::string(volume.f_mntonname);
        }

        const std::size_t slash = path.find_last_of('/');
        if (slash == std::string::npos) { return std::nullopt; }
        if (slash == 0) {
            path = "/";
        } else {
            path.resize(slash);
        }
        if (path == "/") {
            struct statfs root = {};
            return statfs(path.c_str(), &root) == 0
                ? std::optional<std::string>(std::string(root.f_mntonname))
                : std::nullopt;
        }
    }
}

// Ask Disk Arbitration/IOKit for the physical medium behind a mounted volume.
// Unknown media deliberately falls back to the HDD-safe hashing profile.
static TDStorageKind TDStorageKindForPath(const std::string &path) {
    const auto mountPath = TDVolumeMountPathForStorageLookup(path);
    if (!mountPath) { return TDStorageKind::unknown; }

    @autoreleasepool {
        DASessionRef diskSession = DASessionCreate(kCFAllocatorDefault);
        if (diskSession == nullptr) { return TDStorageKind::unknown; }

        NSURL *volumeURL = [NSURL fileURLWithPath:TDNSString(*mountPath)
                                       isDirectory:YES];
        DADiskRef disk = volumeURL == nil
            ? nullptr
            : DADiskCreateFromVolumePath(kCFAllocatorDefault,
                                          diskSession,
                                          (__bridge CFURLRef)volumeURL);
        if (disk == nullptr) {
            CFRelease(diskSession);
            return TDStorageKind::unknown;
        }

        io_service_t media = DADiskCopyIOMedia(disk);
        CFTypeRef characteristics = media == IO_OBJECT_NULL
            ? nullptr
            : IORegistryEntrySearchCFProperty(
                media,
                kIOServicePlane,
                CFSTR(kIOPropertyDeviceCharacteristicsKey),
                kCFAllocatorDefault,
                kIORegistryIterateParents);

        TDStorageKind result = TDStorageKind::unknown;
        if (characteristics != nullptr
            && CFGetTypeID(characteristics) == CFDictionaryGetTypeID()) {
            const auto *dictionary = static_cast<CFDictionaryRef>(characteristics);
            const auto *medium = static_cast<CFStringRef>(
                CFDictionaryGetValue(dictionary, CFSTR(kIOPropertyMediumTypeKey)));
            if (medium != nullptr && CFGetTypeID(medium) == CFStringGetTypeID()) {
                if (CFStringCompare(medium,
                                    CFSTR(kIOPropertyMediumTypeRotationalKey),
                                    0) == kCFCompareEqualTo) {
                    result = TDStorageKind::rotational;
                } else if (CFStringCompare(medium,
                                           CFSTR(kIOPropertyMediumTypeSolidStateKey),
                                           0) == kCFCompareEqualTo) {
                    result = TDStorageKind::solidState;
                }
            }
        }

        if (characteristics != nullptr) { CFRelease(characteristics); }
        if (media != IO_OBJECT_NULL) { IOObjectRelease(media); }
        CFRelease(disk);
        CFRelease(diskSession);
        return result;
    }
}

static bool TDHasPrefix(const std::string &value, const char *prefix) {
    return value.rfind(prefix, 0) == 0;
}

static std::optional<std::vector<char>> TDFetchURLData(const std::string &value, std::string &errorMessage) {
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:TDNSString(value)];
        if (url == nil) {
            errorMessage = "Invalid URL";
            return std::nullopt;
        }

        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (data == nil) {
            errorMessage = TDStdString(error.localizedDescription ?: @"Failed to load torrent URL");
            return std::nullopt;
        }

        std::vector<char> buffer(data.length);
        if (data.length > 0) {
            std::memcpy(buffer.data(), data.bytes, data.length);
        }
        return buffer;
    }
}

static std::optional<std::vector<char>> TDReadFileData(const std::string &path, std::string &errorMessage) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:TDNSString(path)];
        if (data == nil) {
            errorMessage = "Failed to read torrent file";
            return std::nullopt;
        }
        std::vector<char> buffer(data.length);
        if (data.length > 0) {
            std::memcpy(buffer.data(), data.bytes, data.length);
        }
        return buffer;
    }
}

static std::string TDInfoHashString(const lt::torrent_info &info) {
    const auto encodeHex = [](const std::string &raw) {
        static constexpr char digits[] = "0123456789abcdef";
        std::string encoded;
        encoded.reserve(raw.size() * 2);
        for (const unsigned char byte : raw) {
            encoded.push_back(digits[byte >> 4]);
            encoded.push_back(digits[byte & 0x0f]);
        }
        return encoded;
    };
    const auto &hashes = info.info_hashes();
    if (hashes.has_v1()) {
        const std::string raw = hashes.v1.to_string();
        return encodeHex(raw);
    }

    const std::string raw = hashes.get_best().to_string();
    return encodeHex(raw);
}
