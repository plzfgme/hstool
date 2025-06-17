const std = @import("std");
const json = std.json;
const http = std.http;

pub const Region = enum {
    us,
    eu,
    kr,
    tw,

    fn getApiHost(self: Region) []const u8 {
        return switch (self) {
            .us => "us.api.blizzard.com",
            .eu => "eu.api.blizzard.com",
            .kr => "kr.api.blizzard.com",
            .tw => "tw.api.blizzard.com",
        };
    }
};

pub fn getBearerToken(allocator: std.mem.Allocator) ![]const u8 {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://hearthstone.blizzard.com/en-us/cards");
    const header_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buf);
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = header_buf,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const html = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(html);

    return try extractAccessTokenFromHtml(allocator, html);
}

const CardApiSettings = struct {
    token: struct {
        access_token: []const u8,
    },
};

fn extractAccessTokenFromHtml(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    const prefix = "cardApiSettings=\"";
    const suffix = "\"";

    const start = std.mem.indexOf(u8, html, prefix) orelse return error.NotFound;
    const sub_html = html[start + prefix.len ..];
    const end = std.mem.indexOf(u8, sub_html, suffix) orelse return error.MalformedHtml;

    const encoded_json = sub_html[0..end];
    const raw_json = try decodeHtmlEntities(allocator, encoded_json);
    defer allocator.free(raw_json);

    var parsed = try json.parseFromSlice(CardApiSettings, allocator, raw_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return try allocator.dupe(u8, parsed.value.token.access_token);
}

fn decodeHtmlEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buffer = try allocator.alloc(u8, input.len);
    defer allocator.free(buffer);
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "&quot;")) {
            buffer[j] = '"';
            i += 6;
            j += 1;
        } else {
            buffer[j] = input[i];
            i += 1;
            j += 1;
        }
    }

    return try allocator.dupe(u8, buffer[0..j]);
}

test extractAccessTokenFromHtml {
    const allocator = std.testing.allocator;
    const html = @embedFile("testdata/cards.html.txt");
    const token = try extractAccessTokenFromHtml(allocator, html);
    defer allocator.free(token);
    try std.testing.expectEqualStrings("KRWpkSRImus70XdDJxtFmU78r8l2hXSIpR", token);
}

const RawMetadata = struct {
    slug: []const u8,
    id: i32,
    name: []const u8,
};

pub const Metadata = struct {
    slug: []u8,
    id: i32,
    name: []u8,

    fn fromRaw(allocator: std.mem.Allocator, raw: RawMetadata) !Metadata {
        return .{
            .slug = try allocator.dupe(u8, raw.slug),
            .id = raw.id,
            .name = try allocator.dupe(u8, raw.name),
        };
    }

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.name);
    }

    pub fn clone(self: *const Metadata, allocator: std.mem.Allocator) !Metadata {
        return Metadata{
            .slug = try allocator.dupe(u8, self.slug),
            .id = self.id,
            .name = try allocator.dupe(u8, self.name),
        };
    }
};

pub const FetchMetadataBySetResult = struct {
    value: []Metadata,
    allocator: std.mem.Allocator,

    pub fn deinit(self: FetchMetadataBySetResult) void {
        for (self.value) |item| {
            item.deinit(self.allocator);
        }
        self.allocator.free(self.value);
    }
};

pub const MetadataSet = enum {
    sets,
    set_groups,
    types,
    rarities,
    classes,
    keywords,
    minion_types,
    spell_schools,
    game_modes,

    fn toString(self: MetadataSet) []const u8 {
        return switch (self) {
            .sets => "sets",
            .set_groups => "setGroups",
            .types => "types",
            .rarities => "rarities",
            .classes => "classes",
            .keywords => "keywords",
            .minion_types => "minionTypes",
            .spell_schools => "spellSchools",
            .game_modes => "gameModes",
        };
    }
};

pub const FetchMetadataBySetParams = struct {
    set: MetadataSet,
    bearer_token: []const u8,
    region: Region = .us,
    locale: []const u8 = "en_US",
};

pub fn fetchMetadataBySet(
    allocator: std.mem.Allocator,
    params: FetchMetadataBySetParams,
) !FetchMetadataBySetResult {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://{s}/hearthstone/metadata/{s}?locale={s}",
        .{ params.region.getApiHost(), params.set.toString(), params.locale },
    );

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{params.bearer_token});
    defer allocator.free(auth_header);

    const uri = try std.Uri.parse(url);
    const header_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buf);
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = header_buf,
        .headers = .{
            .authorization = .{ .override = auth_header },
        },
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024);
    defer allocator.free(body);

    return try parseMetadataArrayFromJson(allocator, body);
}

fn parseMetadataArrayFromJson(allocator: std.mem.Allocator, json_data: []const u8) !FetchMetadataBySetResult {
    var parsed = try json.parseFromSlice([]RawMetadata, allocator, json_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const result = try allocator.alloc(Metadata, parsed.value.len);
    for (parsed.value, 0..) |item, i| {
        result[i] = try Metadata.fromRaw(allocator, item);
    }

    return .{
        .value = result,
        .allocator = allocator,
    };
}

test parseMetadataArrayFromJson {
    const allocator = std.testing.allocator;
    const sample_json =
        \\[
        \\  {"slug":"fire","id":2,"name":"Fire"},
        \\  {"slug":"frost","id":3,"name":"Frost"}
        \\]
    ;

    const result = try parseMetadataArrayFromJson(allocator, sample_json);
    defer result.deinit();

    const items = result.value;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("fire", items[0].slug);
    try std.testing.expectEqual(@as(i32, 2), items[0].id);
    try std.testing.expectEqualStrings("Frost", items[1].name);
}

const RawCard = struct {
    id: i32,
    collectible: i32,
    slug: []const u8,
    multiClassIds: []const i32,
    cardTypeId: i32,
    cardSetId: i32,
    name: []const u8,
    text: []const u8,
    isZilliaxFunctionalModule: bool,
    isZilliaxCosmeticModule: bool,
    classId: ?i32,
    factionId: ?[]const i32 = null,
    parentId: ?i32 = null,
    childIds: ?[]const i32 = null,
    copyOfCardId: ?[]const i32 = null,
    keywordIds: ?[]const i32 = null,
    minionTypeId: ?i32 = null,
    spellSchoolId: ?i32 = null,
    rarityId: ?i32 = null,
    health: ?i32 = null,
    attack: ?i32 = null,
    manaCost: ?i32 = null,
    armor: ?i32 = null,
    runeCost: ?struct {
        blood: i32,
        frost: i32,
        unholy: i32,
    } = null,
    artistName: ?[]const u8 = null,
    flavorText: ?[]const u8 = null,
    image: ?[]const u8 = null,
    imageGold: ?[]const u8 = null,
    cropImage: ?[]const u8 = null,
};

pub const RuneCost = struct {
    frost: i32,
    blood: i32,
    unholy: i32,
};

pub const Card = struct {
    id: i32,
    collectible: bool,
    slug: []u8,
    multi_class_ids: []i32,
    card_type_id: i32,
    card_set_id: i32,
    name: []u8,
    text: []u8,
    is_zilliax_functional_module: bool,
    is_zilliax_cosmetic_module: bool,
    class_id: ?i32 = null,
    faction_id: ?[]i32 = null,
    parent_id: ?i32 = null,
    child_ids: ?[]i32 = null,
    copy_of_card_id: ?[]i32 = null,
    keyword_ids: ?[]i32 = null,
    minion_type_id: ?i32 = null,
    spell_school_id: ?i32 = null,
    rarity_id: ?i32 = null,
    health: ?i32 = null,
    attack: ?i32 = null,
    mana_cost: ?i32 = null,
    armor: ?i32 = null,
    rune_cost: ?RuneCost = null,
    artist_name: ?[]u8 = null,
    flavor_text: ?[]u8 = null,
    image: ?[]u8 = null,
    image_gold: ?[]u8 = null,
    crop_image: ?[]u8 = null,

    fn fromRaw(allocator: std.mem.Allocator, raw: RawCard) !Card {
        return .{
            .id = raw.id,
            .collectible = raw.collectible == 1,
            .slug = try allocator.dupe(u8, raw.slug),
            .multi_class_ids = try allocator.dupe(i32, raw.multiClassIds),
            .card_type_id = raw.cardTypeId,
            .card_set_id = raw.cardSetId,
            .name = try allocator.dupe(u8, raw.name),
            .text = try allocator.dupe(u8, raw.text),
            .is_zilliax_functional_module = raw.isZilliaxFunctionalModule,
            .is_zilliax_cosmetic_module = raw.isZilliaxCosmeticModule,
            .class_id = raw.classId,
            .faction_id = if (raw.factionId) |ids| try allocator.dupe(i32, ids) else null,
            .parent_id = raw.parentId,
            .child_ids = if (raw.childIds) |ids| try allocator.dupe(i32, ids) else null,
            .copy_of_card_id = if (raw.copyOfCardId) |ids| try allocator.dupe(i32, ids) else null,
            .keyword_ids = if (raw.keywordIds) |ids| try allocator.dupe(i32, ids) else null,
            .minion_type_id = raw.minionTypeId,
            .spell_school_id = raw.spellSchoolId,
            .rarity_id = raw.rarityId,
            .health = raw.health,
            .attack = raw.attack,
            .mana_cost = raw.manaCost,
            .armor = raw.armor,
            .rune_cost = if (raw.runeCost) |rc| RuneCost{
                .frost = rc.frost,
                .blood = rc.blood,
                .unholy = rc.unholy,
            } else null,
            .artist_name = if (raw.artistName) |name| try allocator.dupe(u8, name) else null,
            .flavor_text = if (raw.flavorText) |text| try allocator.dupe(u8, text) else null,
            .image = if (raw.image) |img| try allocator.dupe(u8, img) else null,
            .image_gold = if (raw.imageGold) |img| try allocator.dupe(u8, img) else null,
            .crop_image = if (raw.cropImage) |img| try allocator.dupe(u8, img) else null,
        };
    }

    pub fn deinit(self: Card, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.multi_class_ids);
        allocator.free(self.name);
        allocator.free(self.text);
        if (self.faction_id) |ids| allocator.free(ids);
        if (self.child_ids) |ids| allocator.free(ids);
        if (self.copy_of_card_id) |ids| allocator.free(ids);
        if (self.keyword_ids) |ids| allocator.free(ids);
        if (self.artist_name) |name| allocator.free(name);
        if (self.flavor_text) |text| allocator.free(text);
        if (self.image) |img| allocator.free(img);
        if (self.image_gold) |img| allocator.free(img);
        if (self.crop_image) |img| allocator.free(img);
    }

    pub fn clone(self: *const Card, allocator: std.mem.Allocator) !Card {
        return Card{
            .id = self.id,
            .collectible = self.collectible,
            .slug = try allocator.dupe(u8, self.slug),
            .multi_class_ids = try allocator.dupe(i32, self.multi_class_ids),
            .card_type_id = self.card_type_id,
            .card_set_id = self.card_set_id,
            .name = try allocator.dupe(u8, self.name),
            .text = try allocator.dupe(u8, self.text),
            .is_zilliax_functional_module = self.is_zilliax_functional_module,
            .is_zilliax_cosmetic_module = self.is_zilliax_cosmetic_module,
            .class_id = self.class_id,
            .faction_id = if (self.faction_id) |ids| try allocator.dupe(i32, ids) else null,
            .parent_id = self.parent_id,
            .child_ids = if (self.child_ids) |ids| try allocator.dupe(i32, ids) else null,
            .copy_of_card_id = if (self.copy_of_card_id) |ids| try allocator.dupe(i32, ids) else null,
            .keyword_ids = if (self.keyword_ids) |ids| try allocator.dupe(i32, ids) else null,
            .minion_type_id = self.minion_type_id,
            .spell_school_id = self.spell_school_id,
            .rarity_id = self.rarity_id,
            .health = self.health,
            .attack = self.attack,
            .mana_cost = self.mana_cost,
            .armor = self.armor,
            .rune_cost = self.rune_cost,
            .artist_name = if (self.artist_name) |n| try allocator.dupe(u8, n) else null,
            .flavor_text = if (self.flavor_text) |t| try allocator.dupe(u8, t) else null,
            .image = if (self.image) |i| try allocator.dupe(u8, i) else null,
            .image_gold = if (self.image_gold) |i| try allocator.dupe(u8, i) else null,
            .crop_image = if (self.crop_image) |i| try allocator.dupe(u8, i) else null,
        };
    }
};

pub const FetchCardByIdResult = struct {
    value: Card,
    allocator: std.mem.Allocator,

    pub fn deinit(self: FetchCardByIdResult) void {
        self.value.deinit(self.allocator);
    }
};

pub const FetchCardByIdParams = struct {
    id: u32,
    bearer_token: []const u8,

    region: Region = .us,
    locale: []const u8 = "en_US",
};

pub fn fetchCardById(
    allocator: std.mem.Allocator,
    params: FetchCardByIdParams,
) !FetchCardByIdResult {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://{s}/hearthstone/cards/{d}?locale={s}",
        .{ params.region.getApiHost(), params.id, params.locale },
    );

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{params.bearer_token});
    defer allocator.free(auth_header);

    const uri = try std.Uri.parse(url);
    const header_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buf);
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = header_buf,
        .headers = .{
            .authorization = .{ .override = auth_header },
        },
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 16 * 1024);
    defer allocator.free(body);

    return try parseCardFromJson(allocator, body);
}

fn parseCardFromJson(allocator: std.mem.Allocator, json_data: []const u8) !FetchCardByIdResult {
    var parsed = try json.parseFromSlice(RawCard, allocator, json_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const card = try Card.fromRaw(allocator, parsed.value);

    return .{
        .value = card,
        .allocator = allocator,
    };
}

test parseCardFromJson {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"id":678,"collectible":1,"slug":"678-treant","classId":1,"multiClassIds":[],"cardTypeId":4,"cardSetId":2,"name":"Treant","text":"<b>Taunt</b>","keywordIds":[1],"isZilliaxFunctionalModule":false,"isZilliaxCosmeticModule":false,"manaCost":1,"attack":2,"health":2,"image":"https://example.com/image.png"}
    ;

    const result = try parseCardFromJson(allocator, json_str);
    defer result.deinit();

    const card = result.value;
    try std.testing.expectEqual(@as(i32, 678), card.id);
    try std.testing.expectEqualStrings("Treant", card.name);
    try std.testing.expectEqualStrings("<b>Taunt</b>", card.text);
    try std.testing.expectEqual(@as(?i32, 1), card.mana_cost);
    try std.testing.expectEqual(@as(?i32, 2), card.attack);
    try std.testing.expectEqual(@as(?i32, 2), card.health);
    try std.testing.expect(card.collectible);
}

pub const default_page_size: i32 = 40;

pub const SearchCardsParams = struct {
    bearer_token: []const u8,

    region: Region = .us,
    locale: []const u8 = "en_US",
    set: ?[]const u8 = null,
    class: ?[]const u8 = null,
    mana_cost: ?[]const i32 = null,
    attack: ?[]const i32 = null,
    health: ?[]const i32 = null,
    collectible: ?[]const i32 = null,
    rarity: ?[]const u8 = null,
    type_: ?[]const u8 = null,
    minion_type: ?[]const u8 = null,
    keyword: ?[]const u8 = null,
    text_filter: ?[]const u8 = null,
    game_mode: ?[]const u8 = null,
    spell_school: ?[]const u8 = null,
    page_size: ?i32 = default_page_size,
    // Useful only with SearchCardsPaged
    page: ?i32 = null,
};

pub const SearchCardsResult = struct {
    value: []Card,
    allocator: std.mem.Allocator,

    pub fn deinit(self: SearchCardsResult) void {
        for (self.value) |card| {
            card.deinit(self.allocator);
        }
        self.allocator.free(self.value);
    }
};

const RawCards = struct {
    cards: []const RawCard,
};

fn buildQueryString(allocator: std.mem.Allocator, params: SearchCardsParams) ![]u8 {
    var query_parts = std.ArrayList([]u8).init(allocator);
    defer {
        for (query_parts.items) |part| {
            allocator.free(part);
        }
        query_parts.deinit();
    }

    try query_parts.append(try std.fmt.allocPrint(allocator, "locale={s}", .{params.locale}));

    if (params.set) |set| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "set={s}", .{set}));
    }

    if (params.class) |class| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "class={s}", .{class}));
    }

    if (params.mana_cost) |mana_costs| {
        var mana_buf = std.ArrayList(u8).init(allocator);
        defer mana_buf.deinit();

        for (mana_costs, 0..) |cost, i| {
            if (i > 0) try mana_buf.append(',');
            try mana_buf.writer().print("{d}", .{cost});
        }
        try query_parts.append(try std.fmt.allocPrint(allocator, "manaCost={s}", .{mana_buf.items}));
    }

    if (params.attack) |attacks| {
        var attack_buf = std.ArrayList(u8).init(allocator);
        defer attack_buf.deinit();

        for (attacks, 0..) |att, i| {
            if (i > 0) try attack_buf.append(',');
            try attack_buf.writer().print("{d}", .{att});
        }
        try query_parts.append(try std.fmt.allocPrint(allocator, "attack={s}", .{attack_buf.items}));
    }

    if (params.health) |healths| {
        var health_buf = std.ArrayList(u8).init(allocator);
        defer health_buf.deinit();

        for (healths, 0..) |hp, i| {
            if (i > 0) try health_buf.append(',');
            try health_buf.writer().print("{d}", .{hp});
        }
        try query_parts.append(try std.fmt.allocPrint(allocator, "health={s}", .{health_buf.items}));
    }

    if (params.collectible) |collectibles| {
        var collectible_buf = std.ArrayList(u8).init(allocator);
        defer collectible_buf.deinit();

        for (collectibles, 0..) |col, i| {
            if (i > 0) try collectible_buf.append(',');
            try collectible_buf.writer().print("{d}", .{col});
        }
        try query_parts.append(try std.fmt.allocPrint(allocator, "collectible={s}", .{collectible_buf.items}));
    }

    if (params.rarity) |rarity| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "rarity={s}", .{rarity}));
    }

    if (params.type_) |type_val| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "type={s}", .{type_val}));
    }

    if (params.minion_type) |minion_type| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "minionType={s}", .{minion_type}));
    }

    if (params.keyword) |keyword| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "keyword={s}", .{keyword}));
    }

    if (params.text_filter) |text_filter| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "textFilter={s}", .{text_filter}));
    }

    if (params.game_mode) |game_mode| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "gameMode={s}", .{game_mode}));
    }

    if (params.spell_school) |spell_school| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "spellSchool={s}", .{spell_school}));
    }

    if (params.page_size) |page_size| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "pageSize={d}", .{page_size}));
    }

    if (params.page) |page| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "page={d}", .{page}));
    }

    var total_len: usize = 0;
    for (query_parts.items) |part| {
        total_len += part.len;
    }
    if (query_parts.items.len > 0) {
        total_len += query_parts.items.len - 1;
    }

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (query_parts.items, 0..) |part, i| {
        if (i > 0) {
            result[pos] = '&';
            pos += 1;
        }
        @memcpy(result[pos .. pos + part.len], part);
        pos += part.len;
    }

    return result;
}

test buildQueryString {
    const allocator = std.testing.allocator;

    const params = SearchCardsParams{
        .bearer_token = "test_token",
        .locale = "en_US",
        .set = "classic",
        .class = "mage",
        .mana_cost = &[_]i32{ 1, 2, 3 },
    };

    const query = try buildQueryString(allocator, params);
    defer allocator.free(query);

    try std.testing.expect(std.mem.indexOf(u8, query, "locale=en_US") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "set=classic") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "class=mage") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "manaCost=1,2,3") != null);
}

fn parseCardsFromJsonInto(allocator: std.mem.Allocator, json_data: []const u8, list: *std.ArrayList(Card)) !usize {
    var parsed = try json.parseFromSlice(RawCards, allocator, json_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const raw_cards = parsed.value.cards;

    for (raw_cards) |raw_card| {
        const card = try Card.fromRaw(allocator, raw_card);
        try list.append(card);
    }

    return raw_cards.len;
}

test parseCardsFromJsonInto {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"cards":[
        \\{"id":678,"collectible":1,"slug":"678-treant","classId":1,"multiClassIds":[],"cardTypeId":4,"cardSetId":2,"name":"Treant","text":"<b>Taunt</b>","keywordIds":[1],"isZilliaxFunctionalModule":false,"isZilliaxCosmeticModule":false,"manaCost":1,"attack":2,"health":2,"image":"https://example.com/image.png"},
        \\{"id":123456,"collectible":0,"slug":"123456-treant","classId":2,"multiClassIds":[],"cardTypeId":4,"cardSetId":2,"name":"Stealth Treant","text":"<b>Stealth</b>","keywordIds":[2],"isZilliaxFunctionalModule":false,"isZilliaxCosmeticModule":false,"manaCost":2,"attack":3,"health":4,"image":"https://example.com/image.png"}
        \\]}
    ;

    var card_list = std.ArrayList(Card).init(allocator);
    defer {
        for (card_list.items) |card| {
            card.deinit(allocator);
        }
        card_list.deinit();
    }
    const size = try parseCardsFromJsonInto(allocator, json_str, &card_list);
    try std.testing.expectEqual(2, size);

    const cards = card_list.items;
    try std.testing.expectEqual(@as(i32, 678), cards[0].id);
    try std.testing.expectEqualStrings("Treant", cards[0].name);
    try std.testing.expectEqualStrings("<b>Taunt</b>", cards[0].text);
    try std.testing.expectEqual(@as(?i32, 1), cards[0].mana_cost);
    try std.testing.expectEqual(@as(?i32, 2), cards[0].attack);
    try std.testing.expectEqual(@as(?i32, 2), cards[0].health);
    try std.testing.expect(cards[0].collectible);
    try std.testing.expectEqual(@as(i32, 123456), cards[1].id);
    try std.testing.expectEqualStrings("Stealth Treant", cards[1].name);
    try std.testing.expectEqualStrings("<b>Stealth</b>", cards[1].text);
    try std.testing.expectEqual(@as(?i32, 2), cards[1].mana_cost);
    try std.testing.expectEqual(@as(?i32, 3), cards[1].attack);
    try std.testing.expectEqual(@as(?i32, 4), cards[1].health);
    try std.testing.expect(cards[0].collectible);
}

fn searchCardsInternal(
    allocator: std.mem.Allocator,
    params: SearchCardsParams,
    all_pages: bool,
) !SearchCardsResult {
    var all_cards = std.ArrayList(Card).init(allocator);
    defer all_cards.deinit();

    var current_page: i32 = if (params.page) |p| p else 1;
    var modified_params = params;
    if (modified_params.page_size == null) {
        modified_params.page_size = default_page_size;
    }

    while (true) {
        modified_params.page = current_page;

        var client = http.Client{ .allocator = allocator };
        defer client.deinit();

        const query_string = try buildQueryString(allocator, modified_params);
        defer allocator.free(query_string);

        var url_buf: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "https://{s}/hearthstone/cards?{s}",
            .{ params.region.getApiHost(), query_string },
        );

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{params.bearer_token});
        defer allocator.free(auth_header);

        const uri = try std.Uri.parse(url);
        const header_buf = try allocator.alloc(u8, 1024);
        defer allocator.free(header_buf);
        var req = try client.open(.GET, uri, .{
            .server_header_buffer = header_buf,
            .headers = .{
                .authorization = .{ .override = auth_header },
            },
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 100 * 1024);
        defer allocator.free(body);

        const size = try parseCardsFromJsonInto(allocator, body, &all_cards);

        if (!all_pages or size < modified_params.page_size.?) {
            break;
        }

        current_page += 1;
    }

    const final_cards = try allocator.alloc(Card, all_cards.items.len);
    @memcpy(final_cards, all_cards.items);

    return .{
        .value = final_cards,
        .allocator = allocator,
    };
}

pub fn searchCardsPaged(
    allocator: std.mem.Allocator,
    params: SearchCardsParams,
) !SearchCardsResult {
    return try searchCardsInternal(allocator, params, false);
}

pub fn searchCards(
    allocator: std.mem.Allocator,
    params: SearchCardsParams,
) !SearchCardsResult {
    return try searchCardsInternal(allocator, params, true);
}

const RawCardBack = struct {
    id: i32,
    sortCategory: i32,
    text: []const u8,
    name: []const u8,
    image: []const u8,
    slug: []const u8,
};

pub const CardBack = struct {
    id: i32,
    sort_category: i32,
    text: []u8,
    name: []u8,
    image: []u8,
    slug: []u8,

    fn fromRaw(allocator: std.mem.Allocator, raw: RawCardBack) !CardBack {
        return .{
            .id = raw.id,
            .sort_category = raw.sortCategory,
            .text = try allocator.dupe(u8, raw.text),
            .name = try allocator.dupe(u8, raw.name),
            .image = try allocator.dupe(u8, raw.image),
            .slug = try allocator.dupe(u8, raw.slug),
        };
    }

    pub fn deinit(self: CardBack, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.name);
        allocator.free(self.image);
        allocator.free(self.slug);
    }

    pub fn clone(self: *const CardBack, allocator: std.mem.Allocator) !CardBack {
        return CardBack{
            .id = self.id,
            .sort_category = self.sort_category,
            .text = try allocator.dupe(u8, self.text),
            .name = try allocator.dupe(u8, self.name),
            .image = try allocator.dupe(u8, self.image),
            .slug = try allocator.dupe(u8, self.slug),
        };
    }
};

pub const FetchCardBackByIdParams = struct {
    id: u32,
    bearer_token: []const u8,
    region: Region = .us,
    locale: []const u8 = "en_US",
};

pub const FetchCardBackByIdResult = struct {
    value: CardBack,
    allocator: std.mem.Allocator,

    pub fn deinit(self: FetchCardBackByIdResult) void {
        self.value.deinit(self.allocator);
    }
};

pub fn fetchCardBackById(allocator: std.mem.Allocator, params: FetchCardBackByIdParams) !FetchCardBackByIdResult {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://{s}/hearthstone/cardbacks/{d}?locale={s}",
        .{ params.region.getApiHost(), params.id, params.locale },
    );

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{params.bearer_token});
    defer allocator.free(auth_header);

    const uri = try std.Uri.parse(url);
    const header_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buf);
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = header_buf,
        .headers = .{
            .authorization = .{ .override = auth_header },
        },
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 16 * 1024);
    defer allocator.free(body);

    return try parseCardBackFromJson(allocator, body);
}

fn parseCardBackFromJson(allocator: std.mem.Allocator, json_data: []const u8) !FetchCardBackByIdResult {
    var parsed = try json.parseFromSlice(RawCardBack, allocator, json_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const card_back = try CardBack.fromRaw(allocator, parsed.value);

    return .{
        .value = card_back,
        .allocator = allocator,
    };
}

test parseCardBackFromJson {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"id":1,"sortCategory":5,"text":"Hearthstone is a very popular game in Pandaria. Official card game of the Shado-Pan! Acquired from achieving Rank 20 in Ranked Play, April 2014.","name":"Pandaria","image":"https://www.example.com/image.png","slug":"1-pandaria"}
    ;

    const result = try parseCardBackFromJson(allocator, json_str);
    defer result.deinit();

    const card_back = result.value;
    try std.testing.expectEqual(1, card_back.id);
    try std.testing.expectEqual(5, card_back.sort_category);
    try std.testing.expectEqualStrings(
        "Hearthstone is a very popular game in Pandaria. Official card game of the Shado-Pan! Acquired from achieving Rank 20 in Ranked Play, April 2014.",
        card_back.text,
    );
    try std.testing.expectEqualStrings("Pandaria", card_back.name);
    try std.testing.expectEqualStrings("https://www.example.com/image.png", card_back.image);
    try std.testing.expectEqualStrings("1-pandaria", card_back.slug);
}
