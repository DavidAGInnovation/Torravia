#pragma once

#include "libtorrent/create_torrent.hpp"

// Creation is a separate, network-free helper invocation. The app keeps its
// security-scoped source access alive and validates its snapshot before/after.
static int TDCreateTorrent() {
    auto emit = [](NSDictionary *event) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        std::cout.write(static_cast<const char *>(json.bytes), json.length);
        std::cout << '\n' << std::flush;
    };
    try {
        namespace lt = libtorrent;
        std::string line;
        if (!std::getline(std::cin, line) || line.size() > 32 * 1024 * 1024) {
            throw std::runtime_error("Invalid torrent creation request.");
        }
        NSData *request = [NSData dataWithBytes:line.data() length:line.size()];
        NSDictionary *options = [NSJSONSerialization JSONObjectWithData:request options:0 error:nil];
        if (![options isKindOfClass:[NSDictionary class]]
            || ![options[@"files"] isKindOfClass:[NSArray class]]
            || ![options[@"root"] isKindOfClass:[NSString class]]
            || ![options[@"format"] isKindOfClass:[NSString class]]) {
            throw std::runtime_error("Invalid torrent creation options.");
        }
        std::vector<lt::create_file_entry> files;
        for (NSDictionary *file in options[@"files"]) {
            NSString *path = file[@"path"];
            if (![path isKindOfClass:[NSString class]] || path.length == 0
                || path.isAbsolutePath || [path.pathComponents containsObject:@".."]
                || [path.pathComponents containsObject:@"."] || [file[@"size"] longLongValue] < 0) {
                throw std::runtime_error("Invalid torrent content path.");
            }
            files.emplace_back(path.UTF8String, [file[@"size"] longLongValue]);
        }
        if (files.empty() || files.size() > 100000) {
            throw std::runtime_error("Invalid torrent file count.");
        }
        lt::create_flags_t flags{};
        NSString *format = options[@"format"];
        if ([format isEqualToString:@"v1"]) flags = lt::create_torrent::v1_only;
        else if ([format isEqualToString:@"v2"]) flags = lt::create_torrent::v2_only;
        else if (![format isEqualToString:@"hybrid"]) throw std::runtime_error("Unknown torrent format.");
        const int pieceSize = [options[@"pieceLength"] intValue];
        if (pieceSize < 16384 || pieceSize > 16 * 1024 * 1024 || (pieceSize & (pieceSize - 1))) {
            throw std::runtime_error("Invalid torrent piece size.");
        }
        lt::create_torrent torrent(std::move(files), pieceSize, flags);
        torrent.set_creator("Torravia");
        torrent.set_comment([options[@"comment"] UTF8String]);
        torrent.set_priv([options[@"private"] boolValue]);
        int tier = 0;
        for (NSString *tracker in options[@"trackers"]) torrent.add_tracker(tracker.UTF8String, tier++);
        int lastPercent = -1;
        int completed = 0;
        lt::set_piece_hashes(torrent, [options[@"root"] UTF8String], [&](lt::piece_index_t) {
            const int percent = ++completed * 100 / std::max(torrent.num_pieces(), 1);
            if (percent != lastPercent) {
                emit(@{@"progress": @(std::min(percent, 100) / 100.0)});
                lastPercent = percent;
            }
        });
        const auto bytes = torrent.generate_buf();
        if (bytes.size() > 64 * 1024 * 1024) throw std::runtime_error("Torrent metadata is too large.");
        NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
        emit(@{@"data": [data base64EncodedStringWithOptions:0]});
        return 0;
    } catch (const std::exception &error) {
        NSString *message = [NSString stringWithUTF8String:error.what()] ?: @"Torrent creation failed.";
        emit(@{@"error": message});
        return 1;
    }
}
