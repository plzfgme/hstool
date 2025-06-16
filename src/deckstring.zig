const std = @import("std");

pub const FormatType = enum(u32) {
    unknown = 0,
    wild = 1,
    standard = 2,
};

pub const CardInclude = struct {
    id: u32,
    count: u32,
};

pub const SideboardEntry = struct {
    id: u32,
    count: u32,
    owner: u32,
};

pub const Deck = struct {
    cards: []CardInclude,
    heroes: []u32,
    format: FormatType,
    sideboards: []SideboardEntry,

    pub fn deinit(self: Deck, allocator: std.mem.Allocator) void {
        allocator.free(self.cards);
        allocator.free(self.heroes);
        allocator.free(self.sideboards);
    }
};

fn readVarint(data: []const u8, index: *usize) !u32 {
    var shift: u5 = 0;
    var result: u32 = 0;
    while (true) {
        if (index.* >= data.len) return error.UnexpectedEOF;
        const byte = data[index.*];
        index.* += 1;
        result |= @as(u32, byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) break;
        shift += 7;
    }
    return result;
}

pub fn parseDeckstring(allocator: std.mem.Allocator, deckstr: []const u8) !Deck {
    const codec = std.base64.standard;
    const len = try codec.Decoder.calcSizeForSlice(deckstr);
    const decoded = try allocator.alloc(u8, len);
    defer allocator.free(decoded);
    try codec.Decoder.decode(decoded, deckstr);

    var idx: usize = 0;
    if (decoded.len == 0 or decoded[0] != 0) return error.InvalidDeckstring;
    idx += 1;

    const version = try readVarint(decoded, &idx);
    if (version != 1) return error.UnsupportedVersion;

    const fmt_val = try readVarint(decoded, &idx);
    const format: FormatType = switch (fmt_val) {
        1 => FormatType.wild,
        2 => FormatType.standard,
        else => FormatType.unknown,
    };

    var heroes = std.ArrayList(u32).init(allocator);
    defer heroes.deinit();
    const numHeroes = try readVarint(decoded, &idx);
    for (0..numHeroes) |_| {
        const hid = try readVarint(decoded, &idx);
        try heroes.append(hid);
    }
    std.sort.block(u32, heroes.items, {}, comptime std.sort.asc(u32));

    var cards = std.ArrayList(CardInclude).init(allocator);
    defer cards.deinit();
    const numX1 = try readVarint(decoded, &idx);
    for (0..numX1) |_| {
        const cid = try readVarint(decoded, &idx);
        try cards.append(CardInclude{ .id = cid, .count = 1 });
    }
    const numX2 = try readVarint(decoded, &idx);
    for (0..numX2) |_| {
        const cid = try readVarint(decoded, &idx);
        try cards.append(CardInclude{ .id = cid, .count = 2 });
    }
    const numXn = try readVarint(decoded, &idx);
    for (0..numXn) |_| {
        const cid = try readVarint(decoded, &idx);
        const cnt = try readVarint(decoded, &idx);
        try cards.append(CardInclude{ .id = cid, .count = cnt });
    }
    std.sort.block(CardInclude, cards.items, {}, comptime struct {
        pub fn lessThan(_: void, a: CardInclude, b: CardInclude) bool {
            return a.id < b.id;
        }
    }.lessThan);

    var sideboards = std.ArrayList(SideboardEntry).init(allocator);
    defer sideboards.deinit();
    if (idx < decoded.len and decoded[idx] == 1) {
        idx += 1;
        const sb1 = try readVarint(decoded, &idx);
        for (0..sb1) |_| {
            const cid = try readVarint(decoded, &idx);
            const owner = try readVarint(decoded, &idx);
            try sideboards.append(SideboardEntry{ .id = cid, .count = 1, .owner = owner });
        }
        const sb2 = try readVarint(decoded, &idx);
        for (0..sb2) |_| {
            const cid = try readVarint(decoded, &idx);
            const owner = try readVarint(decoded, &idx);
            try sideboards.append(SideboardEntry{ .id = cid, .count = 2, .owner = owner });
        }
        const sbn = try readVarint(decoded, &idx);
        for (0..sbn) |_| {
            const cid = try readVarint(decoded, &idx);
            const cnt = try readVarint(decoded, &idx);
            const owner = try readVarint(decoded, &idx);
            try sideboards.append(SideboardEntry{ .id = cid, .count = cnt, .owner = owner });
        }
        std.sort.block(SideboardEntry, sideboards.items, {}, comptime struct {
            pub fn lessThan(_: void, a: SideboardEntry, b: SideboardEntry) bool {
                if (a.owner != b.owner) return a.owner < b.owner;
                return a.id < b.id;
            }
        }.lessThan);
    }

    const heroes_slice = try heroes.toOwnedSlice();
    const cards_slice = try cards.toOwnedSlice();
    const sideboards_slice = try sideboards.toOwnedSlice();

    return Deck{
        .cards = cards_slice,
        .heroes = heroes_slice,
        .format = format,
        .sideboards = sideboards_slice,
    };
}

test parseDeckstring {
    const testing = std.testing;
    const allocator = testing.allocator;

    const deckstr =
        "AAEBAZCaBgjlsASotgSX7wTvkQXipAX9xAXPxgXGxwUQvp8EobYElrcE+dsEuNwEutwE9v" ++
        "AEhoMFopkF4KQFlMQFu8QFu8cFuJ4Gz54G0Z4GAAED8J8E/cQFuNkE/cQF/+EE/cQFAAA=";

    const expected_cards = [_]CardInclude{
        .{ .id = 69566, .count = 2 },
        .{ .id = 71781, .count = 1 },
        .{ .id = 72481, .count = 2 },
        .{ .id = 72488, .count = 1 },
        .{ .id = 72598, .count = 2 },
        .{ .id = 77305, .count = 2 },
        .{ .id = 77368, .count = 2 },
        .{ .id = 77370, .count = 2 },
        .{ .id = 79767, .count = 1 },
        .{ .id = 79990, .count = 2 },
        .{ .id = 82310, .count = 2 },
        .{ .id = 84207, .count = 1 },
        .{ .id = 85154, .count = 2 },
        .{ .id = 86624, .count = 2 },
        .{ .id = 86626, .count = 1 },
        .{ .id = 90644, .count = 2 },
        .{ .id = 90683, .count = 2 },
        .{ .id = 90749, .count = 1 },
        .{ .id = 90959, .count = 1 },
        .{ .id = 91067, .count = 2 },
        .{ .id = 91078, .count = 1 },
        .{ .id = 102200, .count = 2 },
        .{ .id = 102223, .count = 2 },
        .{ .id = 102225, .count = 2 },
    };

    const expected_sideboards = [_]SideboardEntry{
        .{ .id = 69616, .count = 1, .owner = 90749 },
        .{ .id = 76984, .count = 1, .owner = 90749 },
        .{ .id = 78079, .count = 1, .owner = 90749 },
    };

    const expected_hero = [_]u32{101648};

    var deck = try parseDeckstring(allocator, deckstr);
    defer deck.deinit(allocator);

    try testing.expect(deck.format == FormatType.wild);
    try testing.expectEqualSlices(u32, &expected_hero, deck.heroes);
    try testing.expectEqualSlices(CardInclude, &expected_cards, deck.cards);
    try testing.expectEqualSlices(SideboardEntry, &expected_sideboards, deck.sideboards);
}
