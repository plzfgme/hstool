const std = @import("std");
const hstool = @import("hstool");

test "getBearerToken" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);
}

test "fetchMetadataBySet" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const metadata = try hstool.api.fetchMetadataBySet(allocator, .{
        .bearer_token = token,
        .set = .spell_schools,
    });
    defer metadata.deinit();
}

test "fetchCardById" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const card = try hstool.api.fetchCardById(allocator, .{
        .bearer_token = token,
        .id = 678,
    });
    defer card.deinit();
}

test "searchCardsPaged" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const cards = try hstool.api.searchCardsPaged(allocator, .{
        .bearer_token = token,
        .class = "hunter",
        .game_mode = "standard",
        .page = 5,
        .page_size = 40,
    });
    defer cards.deinit();
}

test "searchCards" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const cards = try hstool.api.searchCards(allocator, .{
        .bearer_token = token,
        .class = "hunter",
        .game_mode = "standard",
    });
    defer cards.deinit();
}

test "fetchCardBackById" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const card_back = try hstool.api.fetchCardBackById(allocator, .{
        .bearer_token = token,
        .id = 155,
    });
    defer card_back.deinit();
}
